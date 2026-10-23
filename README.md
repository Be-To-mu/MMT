# MMT

An iPhone app that listens for birds, identifies the species, and shows an arrow pointing to where each one is singing.

## How direction works

iOS Spatial Audio capture (`AVCaptureDeviceInput.multichannelAudioMode = .firstOrderAmbisonics`) combines the iPhone's microphone array into 4-channel First Order Ambisonics (W, Y, Z, X; ACN/SN3D). `DOAEstimator` takes the acoustic intensity vector `Re(W* · [X, Y, Z])` per frequency bin and votes it into an energy-weighted azimuth histogram. That gives a 360° bearing plus elevation from a single phone. CoreMotion (`xTrueNorthZVertical`) turns this into a compass bearing, so the arrow stays on target as you turn.

**Requirements:** iPhone 16 or later on iOS 26, using the built-in microphone. Xcode 26.

## Build

```sh
brew install xcodegen uv
tools/setup_birdnet.sh   # downloads BirdNET and converts it to Core ML (~5 min)
cp Local.xcconfig.example Local.xcconfig   # then put your Apple team ID in it
xcodegen            # generates MMT.xcodeproj from project.yml
open MMT.xcodeproj  # run on a real iPhone
```

Run the core tests with `cd Packages/MMTCore && swift test`.

## Status

- [x] DOA estimator, geometry and ring buffer (`Packages/MMTCore`), with unit tests
- [x] FOA capture service, heading service, direction debug screen (clap test)
- [x] AR camera view: world-anchored marker at the sound's bearing + 3D arrow in front of the camera
- [x] BirdNET v2.4 species classifier (Core ML, converted with `tools/convert_birdnet.py`)
- [x] Detected-birds grid with Wikipedia photos → pick one → AR marker and arrow
- [ ] Location/week species filter (BirdNET meta model)
- [ ] Stereo + sweep fallback for older iPhones

## Credits and licensing

App code: MIT (see `LICENSE`). Species identification will use [BirdNET](https://github.com/kahst/BirdNET-Analyzer) (K. Lisa Yang Center for Conservation Bioacoustics / Chemnitz University of Technology). The BirdNET model is licensed **CC BY-NC-SA 4.0**, so builds that include it are non-commercial only. Bird photos come from Wikipedia/Wikimedia Commons under their respective licenses.
