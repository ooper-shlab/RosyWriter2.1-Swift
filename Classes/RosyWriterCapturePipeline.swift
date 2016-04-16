//
//  RosyWriterCapturePipeline.swift
//  RosyWriter
//
//  Translated by OOPer in cooperation with shlab.jp,  on 2015/1/18.
//
//
//
 /*
     File: RosyWriterCapturePipeline.h
     File: RosyWriterCapturePipeline.m
 Abstract: The class that creates and manages the AVCaptureSession
  Version: 2.1

 Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
 Inc. ("Apple") in consideration of your agreement to the following
 terms, and your use, installation, modification or redistribution of
 this Apple software constitutes acceptance of these terms.  If you do
 not agree with these terms, please do not use, install, modify or
 redistribute this Apple software.

 In consideration of your agreement to abide by the following terms, and
 subject to these terms, Apple grants you a personal, non-exclusive
 license, under Apple's copyrights in this original Apple software (the
 "Apple Software"), to use, reproduce, modify and redistribute the Apple
 Software, with or without modifications, in source and/or binary forms;
 provided that if you redistribute the Apple Software in its entirety and
 without modifications, you must retain this notice and the following
 text and disclaimers in all such redistributions of the Apple Software.
 Neither the name, trademarks, service marks or logos of Apple Inc. may
 be used to endorse or promote products derived from the Apple Software
 without specific prior written permission from Apple.  Except as
 expressly stated in this notice, no other rights or licenses, express or
 implied, are granted by Apple herein, including but not limited to any
 patent rights that may be infringed by your derivative works or by other
 works in which the Apple Software may be incorporated.

 The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
 MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
 THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
 FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
 OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

 IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
 OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
 MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
 AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
 STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.

 Copyright (C) 2014 Apple Inc. All Rights Reserved.

 */


import UIKit
import AVFoundation


@objc(RosyWriterCapturePipelineDelegate)
protocol RosyWriterCapturePipelineDelegate: NSObjectProtocol {
    
    func capturePipeline(capturePipeline: RosyWriterCapturePipeline, didStopRunningWithError error: NSError)
    
    // Preview
    func capturePipeline(capturePipeline: RosyWriterCapturePipeline, previewPixelBufferReadyForDisplay previewPixelBuffer: CVPixelBuffer)
    func capturePipelineDidRunOutOfPreviewBuffers(capturePipeline: RosyWriterCapturePipeline)
    
    // Recording
    func capturePipelineRecordingDidStart(capturePipeline: RosyWriterCapturePipeline)
    // Can happen at any point after a startRecording call, for example: startRecording->didFail (without a didStart), willStop->didFail (without a didStop)
    func capturePipeline(capturePipeline: RosyWriterCapturePipeline, recordingDidFailWithError error: NSError)
    func capturePipelineRecordingWillStop(capturePipeline: RosyWriterCapturePipeline)
    func capturePipelineRecordingDidStop(capturePipeline: RosyWriterCapturePipeline)
    
}


import CoreMedia
import AssetsLibrary

/*
RETAINED_BUFFER_COUNT is the number of pixel buffers we expect to hold on to from the renderer. This value informs the renderer how to size its buffer pool and how many pixel buffers to preallocate (done in the prepareWithOutputDimensions: method). Preallocation helps to lessen the chance of frame drops in our recording, in particular during recording startup. If we try to hold on to more buffers than RETAINED_BUFFER_COUNT then the renderer will fail to allocate new buffers from its pool and we will drop frames.

A back of the envelope calculation to arrive at a RETAINED_BUFFER_COUNT of '6':
- The preview path only has the most recent frame, so this makes the movie recording path the long pole.
- The movie recorder internally does a dispatch_async to avoid blocking the caller when enqueuing to its internal asset writer.
- Allow 2 frames of latency to cover the dispatch_async and the -[AVAssetWriterInput appendSampleBuffer:] call.
- Then we allow for the encoder to retain up to 4 frames. Two frames are retained while being encoded/format converted, while the other two are to handle encoder format conversion pipelining and encoder startup latency.

Really you need to test and measure the latency in your own application pipeline to come up with an appropriate number. 1080p BGRA buffers are quite large, so it's a good idea to keep this number as low as possible.
*/

private let RETAINED_BUFFER_COUNT = 6

//-DRECORD_AUDIO
//-DLOG_STATUS_TRANSITIONS
//Build Settings>Swift Compiler - Custom Flags>Other Swift Flags

// internal state machine
private enum RosyWriterRecordingStatus: Int {
    case Idle = 0
    case StartingRecording
    case Recording
    case StoppingRecording
}

#if LOG_STATUS_TRANSITIONS
    extension RosyWriterRecordingStatus: CustomStringConvertible {
        var description: String {
            switch self {
            case .Idle:
                return "Idle"
            case .StartingRecording:
                return "StartingRecording"
            case .Recording:
                return "Recording"
            case .StoppingRecording:
                return "StoppingRecording"
            }
        }
    }
#endif


@objc(RosyWriterCapturePipeline)
class RosyWriterCapturePipeline: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, MovieRecorderDelegate {
    // delegate is weak referenced
    // __weak doesn't actually do anything under non-ARC
    private weak var _delegate: RosyWriterCapturePipelineDelegate?
    private var _delegateCallbackQueue: dispatch_queue_t?
    
    private var _previousSecondTimestamps: [CMTime] = []
    
    private var _captureSession: AVCaptureSession?
    private var _videoDevice: AVCaptureDevice?
    private var _audioConnection: AVCaptureConnection?
    private var _videoConnection: AVCaptureConnection?
    private var _running: Bool = false
    private var _startCaptureSessionOnEnteringForeground: Bool = false
    private var _applicationWillEnterForegroundNotificationObserver: AnyObject?
    private var _videoCompressionSettings: [String : AnyObject] = [:]
    private var _audioCompressionSettings: [String : AnyObject] = [:]
    
    private var _sessionQueue: dispatch_queue_t
    private var _videoDataOutputQueue: dispatch_queue_t
    
    private var _renderer: RosyWriterRenderer
    // When set to false the GPU will not be used after the setRenderingEnabled: call returns.
    private var _renderingEnabled: Bool = false
    // client can set the orientation for the recorded movie
    var recordingOrientation: AVCaptureVideoOrientation = .Portrait
    
    private var _recordingURL: NSURL
    private var _recordingStatus: RosyWriterRecordingStatus = .Idle
    
    private var _pipelineRunningTask: UIBackgroundTaskIdentifier = 0
    
    private var currentPreviewPixelBuffer: CVPixelBuffer?
    
    // Stats
    private(set) var videoFrameRate: Float = 0.0
    private(set) var videoDimensions: CMVideoDimensions = CMVideoDimensions(width: 0, height: 0)
    private var videoOrientation: AVCaptureVideoOrientation = .Portrait
    
    private var outputVideoFormatDescription: CMFormatDescription?
    private var outputAudioFormatDescription: CMFormatDescription?
    private var recorder: MovieRecorder!
    
    override init() {
        recordingOrientation = .Portrait
        
        _recordingURL = NSURL(fileURLWithPath: NSString.pathWithComponents([NSTemporaryDirectory(), "Movie.MOV"]) as String)
        
        _sessionQueue = dispatch_queue_create("com.apple.sample.capturepipeline.session", DISPATCH_QUEUE_SERIAL)
        
        // In a multi-threaded producer consumer system it's generally a good idea to make sure that producers do not get starved of CPU time by their consumers.
        // In this app we start with VideoDataOutput frames on a high priority queue, and downstream consumers use default priority queues.
        // Audio uses a default priority queue because we aren't monitoring it live and just want to get it into the movie.
        // AudioDataOutput can tolerate more latency than VideoDataOutput as its buffers aren't allocated out of a fixed size pool.
        _videoDataOutputQueue = dispatch_queue_create("com.apple.sample.capturepipeline.video", DISPATCH_QUEUE_SERIAL)
        dispatch_set_target_queue(_videoDataOutputQueue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0))
        
        // USE_XXX_RENDERER is set in the project's build settings for each target
        #if USE_OPENGL_RENDERER
            _renderer = RosyWriterOpenGLRenderer()
            #elseif USE_CPU_RENDERER
            _renderer = RosyWriterCPURenderer()
            #elseif USE_CIFILTER_RENDERER
            _renderer = RosyWriterCIFilterRenderer()
            #elseif USE_OPENCV_RENDERER
            _renderer = RosyWriterOpenCVRenderer()
        #endif
        
        _pipelineRunningTask = UIBackgroundTaskInvalid
        super.init()
    }
    
    deinit {
        
        self.teardownCaptureSession()
        
    }
    
    //MARK: Delegate
    
    func setDelegate(delegate: RosyWriterCapturePipelineDelegate?, callbackQueue delegateCallbackQueue: dispatch_queue_t?) {
        if delegate != nil && delegateCallbackQueue == nil {
            fatalError("Caller must provide a delegateCallbackQueue")
        }
        
        synchronized(self) {
            self._delegate = delegate
            self._delegateCallbackQueue = delegateCallbackQueue
        }
    }
    
    var delegate: RosyWriterCapturePipelineDelegate? {
        var myDelegate: RosyWriterCapturePipelineDelegate? = nil
        synchronized(self) {
            myDelegate = self._delegate
        }
        return myDelegate
    }
    
    //MARK: Capture Session
    // These methods are synchronous
    
    func startRunning() {
        dispatch_sync(_sessionQueue) {
            self.setupCaptureSession()
            
            self._captureSession!.startRunning()
            self._running = true
        }
    }
    
    func stopRunning() {
        dispatch_sync(_sessionQueue) {
            self._running = false
            
            // the captureSessionDidStopRunning method will stop recording if necessary as well, but we do it here so that the last video and audio samples are better aligned
            self.stopRecording() // does nothing if we aren't currently recording
            
            self._captureSession?.stopRunning()
            
            self.captureSessionDidStopRunning()
            
            self.teardownCaptureSession()
        }
    }
    
    private func setupCaptureSession() {
        if _captureSession != nil {
            return
        }
        
        _captureSession = AVCaptureSession()
        
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(RosyWriterCapturePipeline.captureSessionNotification(_:)), name: nil, object: _captureSession)
        _applicationWillEnterForegroundNotificationObserver = NSNotificationCenter.defaultCenter().addObserverForName(UIApplicationWillEnterForegroundNotification, object: UIApplication.sharedApplication(), queue: nil) {note in
            // Retain self while the capture session is alive by referencing it in this observer block which is tied to the session lifetime
            // Client must stop us running before we can be deallocated
            self.applicationWillEnterForeground()
        }
        
        #if RECORD_AUDIO
            /* Audio */
            let audioDevice = AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeAudio)
            let audioIn = try! AVCaptureDeviceInput(device: audioDevice)
            if _captureSession!.canAddInput(audioIn) {
                _captureSession!.addInput(audioIn)
            }
            
            let audioOut = AVCaptureAudioDataOutput()
            // Put audio on its own queue to ensure that our video processing doesn't cause us to drop audio
            let audioCaptureQueue = dispatch_queue_create("com.apple.sample.capturepipeline.audio", DISPATCH_QUEUE_SERIAL)
            audioOut.setSampleBufferDelegate(self, queue: audioCaptureQueue)
            
            if _captureSession!.canAddOutput(audioOut) {
                _captureSession!.addOutput(audioOut)
            }
            _audioConnection = audioOut.connectionWithMediaType(AVMediaTypeAudio)
        #endif // RECORD_AUDIO
        
        /* Video */
        let videoDevice = AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeVideo)
        if videoDevice == nil {
            fatalError("AVCaptureDevice of type AVMediaTypeVideo unavailabel!")
        }
        _videoDevice = videoDevice
        let videoIn: AVCaptureDeviceInput!
        do {
            videoIn = try AVCaptureDeviceInput(device: videoDevice)
        } catch _ {
            videoIn = nil
        }
        if _captureSession!.canAddInput(videoIn) {
            _captureSession!.addInput(videoIn)
        }
        
        let videoOut = AVCaptureVideoDataOutput()
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey : _renderer.inputPixelFormat.n]
        videoOut.setSampleBufferDelegate(self, queue: _videoDataOutputQueue)
        
        // RosyWriter records videos and we prefer not to have any dropped frames in the video recording.
        // By setting alwaysDiscardsLateVideoFrames to NO we ensure that minor fluctuations in system load or in our processing time for a given frame won't cause framedrops.
        // We do however need to ensure that on average we can process frames in realtime.
        // If we were doing preview only we would probably want to set alwaysDiscardsLateVideoFrames to YES.
        videoOut.alwaysDiscardsLateVideoFrames = false
        
        if _captureSession!.canAddOutput(videoOut) {
            _captureSession!.addOutput(videoOut)
        }
        _videoConnection = videoOut.connectionWithMediaType(AVMediaTypeVideo)
        
        var frameRate: Int32
        var sessionPreset = AVCaptureSessionPresetHigh
        var frameDuration = kCMTimeInvalid
        // For single core systems like iPhone 4 and iPod Touch 4th Generation we use a lower resolution and framerate to maintain real-time performance.
        if NSProcessInfo.processInfo().processorCount == 1 {
            if _captureSession!.canSetSessionPreset(AVCaptureSessionPreset640x480) {
                sessionPreset = AVCaptureSessionPreset640x480
            }
            frameRate = 15
        } else {
            #if !USE_OPENGL_RENDERER
                // When using the CPU renderers or the CoreImage renderer we lower the resolution to 720p so that all devices can maintain real-time performance (this is primarily for A5 based devices like iPhone 4s and iPod Touch 5th Generation).
                if _captureSession!.canSetSessionPreset(AVCaptureSessionPreset1280x720) {
                    sessionPreset = AVCaptureSessionPreset1280x720
                }
            #endif // !USE_OPENGL_RENDERER
            
            frameRate = 30
        }
        
        _captureSession!.sessionPreset = sessionPreset
        
        frameDuration = CMTimeMake(1, frameRate)
        
        var error: NSError? = nil
        do {
            try videoDevice.lockForConfiguration()
            videoDevice.activeVideoMaxFrameDuration = frameDuration
            videoDevice.activeVideoMinFrameDuration = frameDuration
            videoDevice.unlockForConfiguration()
        } catch let error1 as NSError {
            error = error1
            NSLog("videoDevice lockForConfiguration returned error %@", error!)
        }
        
        // Get the recommended compression settings after configuring the session/device.
        #if RECORD_AUDIO
            _audioCompressionSettings = audioOut.recommendedAudioSettingsForAssetWriterWithOutputFileType(AVFileTypeQuickTimeMovie) as! [String: AnyObject]
        #endif
        _videoCompressionSettings = videoOut.recommendedVideoSettingsForAssetWriterWithOutputFileType(AVFileTypeQuickTimeMovie) as! [String: AnyObject]
        
        self.videoOrientation = _videoConnection!.videoOrientation
        
        return
    }
    
    private func teardownCaptureSession() {
        if _captureSession != nil {
            NSNotificationCenter.defaultCenter().removeObserver(self, name: nil, object: _captureSession)
            
            NSNotificationCenter.defaultCenter().removeObserver(_applicationWillEnterForegroundNotificationObserver!)
            _applicationWillEnterForegroundNotificationObserver = nil
            
            _captureSession = nil
            
            _videoCompressionSettings = [:]
            _audioCompressionSettings = [:]
        }
    }
    
    func captureSessionNotification(notification: NSNotification) {
        dispatch_async(_sessionQueue) {
            
            if notification.name == AVCaptureSessionWasInterruptedNotification {
                NSLog("session interrupted")
                
                self.captureSessionDidStopRunning()
            } else if notification.name == AVCaptureSessionInterruptionEndedNotification {
                NSLog("session interruption ended")
            } else if notification.name == AVCaptureSessionRuntimeErrorNotification {
                self.captureSessionDidStopRunning()
                
                let error = notification.userInfo![AVCaptureSessionErrorKey]! as! NSError
                if error.code == AVError.DeviceIsNotAvailableInBackground.rawValue {
                    NSLog("device not available in background")
                    
                    // Since we can't resume running while in the background we need to remember this for next time we come to the foreground
                    if self._running {
                        self._startCaptureSessionOnEnteringForeground = true
                    }
                } else if error.code == AVError.MediaServicesWereReset.rawValue {
                    NSLog("media services were reset")
                    self.handleRecoverableCaptureSessionRuntimeError(error)
                } else {
                    self.handleNonRecoverableCaptureSessionRuntimeError(error)
                }
            } else if notification.name == AVCaptureSessionDidStartRunningNotification {
                NSLog("session started running")
            } else if notification.name == AVCaptureSessionDidStopRunningNotification {
                NSLog("session stopped running")
            }
        }
    }
    
    private func handleRecoverableCaptureSessionRuntimeError(error: NSError) {
        if _running {
            _captureSession?.startRunning()
        }
    }
    
    private func handleNonRecoverableCaptureSessionRuntimeError(error: NSError) {
        NSLog("fatal runtime error %@, code %i", error, Int32(error.code))
        
        _running = false
        self.teardownCaptureSession()
        
        synchronized(self) {
            if self.delegate != nil {
                dispatch_async(self._delegateCallbackQueue!) {
                    autoreleasepool {
                        self.delegate!.capturePipeline(self, didStopRunningWithError: error)
                    }
                }
            }
        }
    }
    
    private func captureSessionDidStopRunning() {
        self.stopRecording()
        self.teardownCaptureSession()
    }
    
    private func applicationWillEnterForeground() {
        NSLog("-[%@ %@] called", NSStringFromClass(self.dynamicType), #function)
        
        dispatch_sync(_sessionQueue) {
            if self._startCaptureSessionOnEnteringForeground {
                NSLog("-[%@ %@] manually restarting session", NSStringFromClass(self.dynamicType), #function)
                
                self._startCaptureSessionOnEnteringForeground = false
                if self._running {
                    self._captureSession?.startRunning()
                }
            }
        }
    }
    
    //MARK: Capture Pipeline
    
    private func setupVideoPipelineWithInputFormatDescription(inputFormatDescription: CMFormatDescription) {
        NSLog("-[%@ %@] called", NSStringFromClass(self.dynamicType), #function)
        
        self.videoPipelineWillStartRunning()
        
        self.videoDimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
        _renderer.prepareForInputWithFormatDescription(inputFormatDescription, outputRetainedBufferCountHint: RETAINED_BUFFER_COUNT)
        
        if !_renderer.operatesInPlace,
        let outputFormatDescription = _renderer.outputFormatDescription {
            self.outputVideoFormatDescription = outputFormatDescription!
        } else {
            self.outputVideoFormatDescription = inputFormatDescription
        }
    }
    
    // synchronous, blocks until the pipeline is drained, don't call from within the pipeline
    private func teardownVideoPipeline() {
        // The session is stopped so we are guaranteed that no new buffers are coming through the video data output.
        // There may be inflight buffers on _videoDataOutputQueue however.
        // Synchronize with that queue to guarantee no more buffers are in flight.
        // Once the pipeline is drained we can tear it down safely.
        
        NSLog("-[%@ %@] called", NSStringFromClass(self.dynamicType), #function)
        
        dispatch_sync(_videoDataOutputQueue) {
            if self.outputVideoFormatDescription == nil {
                return
            }
            
            self.outputVideoFormatDescription = nil
            self._renderer.reset()
            self.currentPreviewPixelBuffer = nil
            
            NSLog("-[%@ %@] finished teardown", NSStringFromClass(self.dynamicType), #function)
            
            self.videoPipelineDidFinishRunning()
        }
    }
    
    private func videoPipelineWillStartRunning() {
        NSLog("-[%@ %@] called", NSStringFromClass(self.dynamicType), #function)
        
        assert(_pipelineRunningTask == UIBackgroundTaskInvalid, "should not have a background task active before the video pipeline starts running")
        
        _pipelineRunningTask = UIApplication.sharedApplication().beginBackgroundTaskWithExpirationHandler {
            NSLog("video capture pipeline background task expired")
        }
    }
    
    private func videoPipelineDidFinishRunning() {
        NSLog("-[%@ %@] called", NSStringFromClass(self.dynamicType), #function)
        
        assert(_pipelineRunningTask != UIBackgroundTaskInvalid, "should have a background task active when the video pipeline finishes running")
        
        UIApplication.sharedApplication().endBackgroundTask(_pipelineRunningTask)
        _pipelineRunningTask = UIBackgroundTaskInvalid
    }
    
    // call under @synchronized( self )
    func videoPipelineDidRunOutOfBuffers() {
        // We have run out of buffers.
        // Tell the delegate so that it can flush any cached buffers.
        if self.delegate != nil {
            dispatch_async(_delegateCallbackQueue!) {
                autoreleasepool {
                    self.delegate!.capturePipelineDidRunOutOfPreviewBuffers(self)
                }
            }
        }
    }
    
    var renderingEnabled: Bool {
        set {
            synchronized(_renderer) {
                self._renderingEnabled = newValue
            }
        }
        
        get {
            var myRenderingEnabled = false
            synchronized(self._renderer) {
                myRenderingEnabled = self._renderingEnabled
            }
            return myRenderingEnabled
        }
    }
    
    // call under @synchronized( self )
    private func outputPreviewPixelBuffer(previewPixelBuffer: CVPixelBuffer) {
        if self.delegate != nil {
            // Keep preview latency low by dropping stale frames that have not been picked up by the delegate yet
            self.currentPreviewPixelBuffer = previewPixelBuffer
            
            dispatch_async(_delegateCallbackQueue!) {
                autoreleasepool {
                    var currentPreviewPixelBuffer: CVPixelBuffer? = nil
                    synchronized(self) {
                        currentPreviewPixelBuffer = self.currentPreviewPixelBuffer
                        if currentPreviewPixelBuffer != nil {
                            self.currentPreviewPixelBuffer = nil
                        }
                    }
                    
                    if currentPreviewPixelBuffer != nil {
                        self.delegate!.capturePipeline(self, previewPixelBufferReadyForDisplay: currentPreviewPixelBuffer!)
                    }
                }
            }
        }
    }
    
    func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {
        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        
        if connection === _videoConnection {
            if self.outputVideoFormatDescription == nil {
                // Don't render the first sample buffer.
                // This gives us one frame interval (33ms at 30fps) for setupVideoPipelineWithInputFormatDescription: to complete.
                // Ideally this would be done asynchronously to ensure frames don't back up on slower devices.
                self.setupVideoPipelineWithInputFormatDescription(formatDescription!)
            } else {
                self.renderVideoSampleBuffer(sampleBuffer)
            }
        } else if connection === _audioConnection {
            self.outputAudioFormatDescription = formatDescription
            
            synchronized(self) {
                if _recordingStatus == .Recording {
                    self.recorder.appendAudioSampleBuffer(sampleBuffer)
                }
            }
        }
    }
    
    private func renderVideoSampleBuffer(sampleBuffer: CMSampleBuffer) {
        var renderedPixelBuffer: CVPixelBuffer? = nil
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        self.calculateFramerateAtTimestamp(timestamp)
        
        // We must not use the GPU while running in the background.
        // setRenderingEnabled: takes the same lock so the caller can guarantee no GPU usage once the setter returns.
        let returnFlag: Bool = synchronized(_renderer) {
            if _renderingEnabled {
                let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                renderedPixelBuffer = self._renderer.copyRenderedPixelBuffer(sourcePixelBuffer)
                return false
            } else {
                return true //indicates return from func
            }
        }
        if returnFlag {return}
        
        synchronized(self) {
            if renderedPixelBuffer != nil {
                self.outputPreviewPixelBuffer(renderedPixelBuffer!)
                
                if _recordingStatus == .Recording {
                    self.recorder.appendVideoPixelBuffer(renderedPixelBuffer!, withPresentationTime: timestamp)
                }
                
            } else {
                self.videoPipelineDidRunOutOfBuffers()
            }
        }
    }
    
    //MARK: Recording
    // Must be running before starting recording
    // These methods are asynchronous, see the recording delegate callbacks
    
    func startRecording() {
        synchronized(self) {
            if _recordingStatus != .Idle {
                fatalError("Already recording")
            }
            
            self.transitionToRecordingStatus(.StartingRecording, error: nil)
        }
        
        let recorder = MovieRecorder(URL: _recordingURL)
        
        #if RECORD_AUDIO
            recorder.addAudioTrackWithSourceFormatDescription(self.outputAudioFormatDescription!, settings: _audioCompressionSettings)
        #endif // RECORD_AUDIO
        
        // Front camera recording shouldn't be mirrored
        let videoTransform = self.transformFromVideoBufferOrientationToOrientation(self.recordingOrientation, withAutoMirroring: false)
        
        recorder.addVideoTrackWithSourceFormatDescription(self.outputVideoFormatDescription!, transform: videoTransform, settings: _videoCompressionSettings)
        
        let callbackQueue = dispatch_queue_create("com.apple.sample.capturepipeline.recordercallback", DISPATCH_QUEUE_SERIAL); // guarantee ordering of callbacks with a serial queue
        recorder.setDelegate(self, callbackQueue: callbackQueue)
        self.recorder = recorder
        
        // asynchronous, will call us back with recorderDidFinishPreparing: or recorder:didFailWithError: when done
        recorder.prepareToRecord()
    }
    
    func stopRecording() {
        let returnFlag: Bool = synchronized(self) {
            if _recordingStatus != .Recording {
                return true
            }
            
            self.transitionToRecordingStatus(.StoppingRecording, error: nil)
            return false
        }
        if returnFlag {return}
        
        self.recorder.finishRecording() // asynchronous, will call us back with recorderDidFinishRecording: or recorder:didFailWithError: when done
    }
    
    //MARK: MovieRecorder Delegate
    
    func movieRecorderDidFinishPreparing(recorder: MovieRecorder) {
        synchronized(self) {
            if _recordingStatus != .StartingRecording {
                fatalError("Expected to be in StartingRecording state")
            }
            self.transitionToRecordingStatus(.Recording, error: nil)
        }
    }
    
    func movieRecorder(recorder: MovieRecorder, didFailWithError error: NSError) {
        synchronized(self) {
            self.recorder = nil
            self.transitionToRecordingStatus(.Idle, error: error)
        }
    }
    
    func movieRecorderDidFinishRecording(recorder: MovieRecorder) {
        synchronized(self) {
            if _recordingStatus != .StoppingRecording {
                fatalError("Expected to be in StoppingRecording state")
            }
            
            // No state transition, we are still in the process of stopping.
            // We will be stopped once we save to the assets library.
        }
        
        self.recorder = nil
        
        let library = ALAssetsLibrary()
        library.writeVideoAtPathToSavedPhotosAlbum(_recordingURL) {assetURL, error in
            
            do {
                try NSFileManager.defaultManager().removeItemAtURL(self._recordingURL)
            } catch _ {
            }
            
            synchronized(self) {
                if self._recordingStatus != .StoppingRecording {
                    fatalError("Expected to be in StoppingRecording state")
                }
                self.transitionToRecordingStatus(.Idle, error: error)
            }
        }
    }
    
    //MARK: Recording State Machine
    
    // call under @synchonized( self )
    private func transitionToRecordingStatus(newStatus: RosyWriterRecordingStatus, error: NSError?) {
        var delegateClosure: (() -> Void)? = nil
        let oldStatus = _recordingStatus
        _recordingStatus = newStatus
        
        #if LOG_STATUS_TRANSITIONS
            NSLog("RosyWriterCapturePipeline recording state transition: %@->%@", oldStatus.description, newStatus.description)
        #endif
        
        if newStatus != oldStatus && delegate != nil {
            if error != nil && newStatus == .Idle {
                delegateClosure = {self.delegate!.capturePipeline(self, recordingDidFailWithError: error!)}
            } else {
                // only the above delegate method takes an error
                if oldStatus == .StartingRecording && newStatus == .Recording {
                    delegateClosure = {self.delegate!.capturePipelineRecordingDidStart(self)}
                } else if oldStatus == .Recording && newStatus == .StoppingRecording {
                    delegateClosure = {self.delegate!.capturePipelineRecordingWillStop(self)}
                } else if oldStatus == .StoppingRecording && newStatus == .Idle {
                    delegateClosure = {self.delegate!.capturePipelineRecordingDidStop(self)}
                }
            }
        }
        
        if delegateClosure != nil {
            dispatch_async(_delegateCallbackQueue!) {
                autoreleasepool {
                    delegateClosure!()
                }
            }
        }
    }
    
    //MARK: Utilities
    
    // Auto mirroring: Front camera is mirrored; back camera isn't
    // only valid after startRunning has been called
    func transformFromVideoBufferOrientationToOrientation(orientation: AVCaptureVideoOrientation, withAutoMirroring mirror: Bool) -> CGAffineTransform {
        var transform = CGAffineTransformIdentity
        
        // Calculate offsets from an arbitrary reference orientation (portrait)
        let orientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation(orientation)
        let videoOrientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation(self.videoOrientation)
        
        // Find the difference in angle between the desired orientation and the video orientation
        let angleOffset = orientationAngleOffset - videoOrientationAngleOffset
        transform = CGAffineTransformMakeRotation(angleOffset)
        
        if _videoDevice!.position == .Front {
            if mirror {
                transform = CGAffineTransformScale(transform, -1, 1)
            } else {
                if UIInterfaceOrientationIsPortrait(UIInterfaceOrientation(rawValue: orientation.rawValue)!) {
                    transform = CGAffineTransformRotate(transform, M_PI.g)
                }
            }
        }
        
        return transform
    }
    
    private final func angleOffsetFromPortraitOrientationToOrientation(orientation: AVCaptureVideoOrientation) -> CGFloat {
        var angle: CGFloat = 0.0
        
        switch orientation {
        case .Portrait:
            angle = 0.0
        case .PortraitUpsideDown:
            angle = M_PI.g
        case .LandscapeRight:
            angle = -M_PI_2.g
        case .LandscapeLeft:
            angle = M_PI_2.g
        }
        
        return angle
    }
    
    private func calculateFramerateAtTimestamp(timestamp: CMTime) {
        _previousSecondTimestamps.append(timestamp)
        
        let oneSecond = CMTimeMake(1, 1)
        let oneSecondAgo = CMTimeSubtract(timestamp, oneSecond)
        
        while _previousSecondTimestamps[0] < oneSecondAgo {
            _previousSecondTimestamps.removeAtIndex(0)
        }
        
        if _previousSecondTimestamps.count > 1 {
            let duration: Double = CMTimeGetSeconds(CMTimeSubtract(_previousSecondTimestamps.last!, _previousSecondTimestamps[0]))
            let newRate = Float(_previousSecondTimestamps.count - 1) / duration.f
            self.videoFrameRate = newRate
        }
    }
    
}