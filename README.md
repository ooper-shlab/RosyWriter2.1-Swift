# RosyWriter

Translated by OOPer in cooperation with shlab.jp, on 2015/1/18.

Based on
<https://developer.apple.com/library/content/samplecode/RosyWriter/Introduction/Intro.html#//apple_ref/doc/uid/DTS40011110>
2016-09-13.

As this is a line-by-line translation from the original sample code, "redistribute the Apple Software in its entirety and without modifications" would apply. See LICENSE.txt .
Some faults caused by my translation may exist. Not all features tested.
You should not contact to Apple or SHLab(jp) about any faults caused by my translation.

## Requirements

### Build

iOS 14 SDK and Xcode 12.4

### Target Device

iOS 9.0+

---
#### An experimental migration to use Metal.

- Only RosyWriterCPU (hardly practical?) and RosyWriterCIFilter are available

Some parts of this project utilizes files in [AVCamFilter](https://developer.apple.com/documentation/avfoundation/cameras_and_media_capture/avcamfilter_applying_filters_to_a_capture_stream).
See the original license terms in `AVCamFilter-LICENSE/LICENSE.txt`.

AVCamFilter is the newer sample code and may be containing better coding styles.
Starting with it and add some recording feature would be a preferrable way.
