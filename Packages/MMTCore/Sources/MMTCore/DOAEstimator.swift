import Accelerate
import simd

/// Direction of arrival in the FOA frame: X front, Y left, Z up.
public struct DirectionEstimate: Sendable, Equatable {
    /// Degrees, counter-clockwise from +X towards +Y, in (-180, 180].
    public var azimuth: Double
    /// Degrees above the XY plane.
    public var elevation: Double
    /// Circular spread of the energy around the peak, in degrees (small = sharp source).
    public var spread: Double
    /// Fraction of analysed energy that falls near the peak, 0...1.
    public var confidence: Double

    /// Unit vector in the FOA frame.
    public var vector: SIMD3<Double> {
        let az = azimuth * .pi / 180, el = elevation * .pi / 180
        return SIMD3(cos(az) * cos(el), sin(az) * cos(el), sin(el))
    }
}

/// Estimates where a sound came from using the FOA acoustic intensity vector.
///
/// For each STFT bin the active intensity is I = Re(W* · [X, Y, Z]), which points
/// towards the source. Bins are filtered to a frequency band and to the loudest part
/// of the spectrum, then voted into an energy-weighted azimuth histogram.
public struct DOAEstimator: Sendable {
    public var sampleRate: Double
    public var fftSize: Int
    public var hopSize: Int
    /// Only bins above this percentile of W power (per window) are used.
    public var powerPercentile: Double = 0.8

    public init(sampleRate: Double = 48_000, fftSize: Int = 1024, hopSize: Int = 512) {
        precondition(fftSize.nonzeroBitCount == 1, "fftSize must be a power of two")
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hopSize = hopSize
    }

    public func estimate(_ window: FOAWindow,
                         band: ClosedRange<Double> = 1_000...10_000) -> DirectionEstimate? {
        let n = fftSize
        guard window.frameCount >= n,
              let fft = vDSP.FFT(log2n: vDSP_Length(n.trailingZeroBitCount), radix: .radix2,
                                 ofType: DSPSplitComplex.self) else { return nil }

        let lo = max(1, Int(band.lowerBound / sampleRate * Double(n)))
        let hi = min(n / 2 - 1, Int(band.upperBound / sampleRate * Double(n)))
        guard lo <= hi else { return nil }

        let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                               count: n, isHalfWindow: false)

        struct Bin { var ix: Float; var iy: Float; var iz: Float; var power: Float }
        var bins: [Bin] = []

        var start = 0
        while start + n <= window.frameCount {
            let spectra = [window.w, window.x, window.y, window.z].map { channel in
                spectrum(of: channel[start..<(start + n)], window: hann, fft: fft)
            }
            let (w, x, y, z) = (spectra[0], spectra[1], spectra[2], spectra[3])
            for k in lo...hi {
                bins.append(Bin(ix: w.re[k] * x.re[k] + w.im[k] * x.im[k],
                                iy: w.re[k] * y.re[k] + w.im[k] * y.im[k],
                                iz: w.re[k] * z.re[k] + w.im[k] * z.im[k],
                                power: w.re[k] * w.re[k] + w.im[k] * w.im[k]))
            }
            start += hopSize
        }
        guard !bins.isEmpty else { return nil }

        let sortedPower = bins.map(\.power).sorted()
        let threshold = sortedPower[min(sortedPower.count - 1,
                                        Int(Double(sortedPower.count) * powerPercentile))]
        let loud = bins.filter { $0.power >= threshold && $0.power > 0 }
        guard !loud.isEmpty else { return nil }

        // Energy-weighted 1° azimuth histogram, smoothed circularly.
        var histogram = [Double](repeating: 0, count: 360)
        for b in loud {
            let az = atan2(Double(b.iy), Double(b.ix)) * 180 / .pi
            histogram[(Int(az.rounded()) + 360) % 360] += Double(b.power)
        }
        let smoothed = circularSmooth(histogram, radius: 5)
        guard let peakIndex = smoothed.indices.max(by: { smoothed[$0] < smoothed[$1] }),
              smoothed[peakIndex] > 0 else { return nil }

        // Refine with bins within ±30° of the peak: summed intensity vector gives az/el.
        let peakAz = Double(peakIndex)
        var sum = SIMD3<Double>(repeating: 0)
        var near = 0.0, total = 0.0
        var unitSum = SIMD2<Double>(repeating: 0)
        for b in loud {
            let p = Double(b.power)
            total += p
            let az = atan2(Double(b.iy), Double(b.ix)) * 180 / .pi
            guard angularDistance(az, peakAz) <= 30 else { continue }
            near += p
            sum += SIMD3(Double(b.ix), Double(b.iy), Double(b.iz))
            let r = az * .pi / 180
            unitSum += p * SIMD2(cos(r), sin(r))
        }
        guard near > 0 else { return nil }

        let azimuth = atan2(sum.y, sum.x) * 180 / .pi
        let elevation = atan2(sum.z, (sum.x * sum.x + sum.y * sum.y).squareRoot()) * 180 / .pi
        // Circular standard deviation from mean resultant length.
        let resultant = min(1, simd_length(unitSum) / near)
        let spread = (-2 * log(max(resultant, 1e-9))).squareRoot() * 180 / .pi

        return DirectionEstimate(azimuth: normalizeSigned(azimuth), elevation: elevation,
                                 spread: spread, confidence: near / total)
    }

    private func spectrum(of samples: ArraySlice<Float>, window: [Float],
                          fft: vDSP.FFT<DSPSplitComplex>) -> (re: [Float], im: [Float]) {
        let half = fftSize / 2
        let windowed = vDSP.multiply(samples, window)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var outRe = [Float](repeating: 0, count: half), outIm = [Float](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var input = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes {
                    vDSP.convert(interleavedComplexVector: Array($0.bindMemory(to: DSPComplex.self)),
                                 toSplitComplexVector: &input)
                }
                outRe.withUnsafeMutableBufferPointer { orp in
                    outIm.withUnsafeMutableBufferPointer { oip in
                        var output = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                        fft.forward(input: input, output: &output)
                    }
                }
            }
        }
        return (outRe, outIm)
    }
}

func circularSmooth(_ values: [Double], radius: Int) -> [Double] {
    let n = values.count
    return (0..<n).map { i in
        (-radius...radius).reduce(0) { $0 + values[((i + $1) % n + n) % n] }
    }
}

/// Smallest absolute difference between two angles in degrees.
public func angularDistance(_ a: Double, _ b: Double) -> Double {
    abs(normalizeSigned(a - b))
}

/// Wraps an angle in degrees into (-180, 180].
public func normalizeSigned(_ degrees: Double) -> Double {
    var d = degrees.truncatingRemainder(dividingBy: 360)
    if d <= -180 { d += 360 }
    if d > 180 { d -= 360 }
    return d
}
