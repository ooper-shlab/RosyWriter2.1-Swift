//
//  RosyWriterCapturePipeline.swift
//  RosyWriter
//
//  Translated by OOPer in cooperation with shlab.jp,  on 2015/1/18.
//
//
//
 /*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information

 Abstract:
 The class that creates and manages the AVCaptureSession
 */


import UIKit
import AVFoundation
import Photos

@objc(RosyWriterCapturePipelineDelegate)
protocol RosyWriterCapturePipelineDelegate: NSObjectProtocol {
    
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, didStopRunningWithError error: Error)
    
    // Preview
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, previewPixelBufferReadyForDisplay previewPixelBuffer: CVPixelBuffer)
    func capturePipelineDidRunOutOfPreviewBuffers(_ capturePipeline: RosyWriterCapturePipeline)
    
    // Recording
    func capturePipelineRecordingDidStart(_ capturePipeline: RosyWriterCapturePipeline)
    // Can happen at any point after a startRecording call, for example: startRecording->didFail (without a didStart), willStop->didFail (without a didStop)
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, recordingDidFailWithError error: Error)
    func capturePipelineRecordingWillStop(_ capturePipeline: RosyWriterCapturePipeline)
    func capturePipelineRecordingDidStop(_ capturePipeline: RosyWriterCapturePipeline)
    
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
    case idle = 0
    case startingRecording
    case recording
    case stoppingRecording
}

#if LOG_STATUS_TRANSITIONS
    extension RosyWriterRecordingStatus: CustomStringConvertible {
        var description: String {
            switch self {
            case .idle:
                return "Idle"
            case .startingRecording:
                return "StartingRecording"
            case .recording:
                return "Recording"
            case .stoppingRecording:
                return "StoppingRecording"
            }
        }
    }
#endif


@objc(RosyWriterCapturePipeline)
class RosyWriterCapturePipeline: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, MovieRecorderDelegate {
    private var _previousSecondTimestamps: [CMTime] = []
    
    private var _captureSession: AVCaptureSession?
    private var _videoDevice: AVCaptureDevice?
    var videoDevice: AVCaptureDevice? {_videoDevice}
    private var _audioConnection: AVCaptureConnection?
    private var _videoConnection: AVCaptureConnection?
    var videoConnection: AVCaptureConnection? {_videoConnection}
    private var _videoBufferOrientation: AVCaptureVideoOrientation = .portrait
    private var _running: Bool = false
    private var _startCaptureSessionOnEnteringForeground: Bool = false
    private var _applicationWillEnterForegroundNotificationObserver: AnyObject?
    private var _videoCompressionSettings: [String : Any] = [:]
    private var _audioCompressionSettings: [String : Any] = [:]
    
    private var _sessionQueue: DispatchQueue
    private var _videoDataOutputQueue: DispatchQueue
    
    private var _renderer: RosyWriterRenderer
    // When set to false the GPU will not be used after the setRenderingEnabled: call returns.
    private /*atomic*/ var _renderingEnabled: Bool = false
    
    private var _recorder: MovieRecorder!
    // client can set the orientation for the recorded movie
    var /*atomic*/ recordingOrientation: AVCaptureVideoOrientation = .portrait
    
    private var _recordingURL: URL
    private var _recordingStatus: RosyWriterRecordingStatus = .idle
    
    private var _pipelineRunningTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 0)
    
    // delegate is weak referenced
    // __weak doesn't actually do anything under non-ARC
    private weak var _delegate: RosyWriterCapturePipelineDelegate?
    private var _delegateCallbackQueue: DispatchQueue?
    
    // Stats
    private(set) /*atomic*/ var videoFrameRate: Float = 0.0
    private(set) /*atomic*/ var videoDimensions: CMVideoDimensions = CMVideoDimensions(width: 0, height: 0)
    
    private var currentPreviewPixelBuffer: CVPixelBuffer?
    private var outputVideoFormatDescription: CMFormatDescription?
    private var outputAudioFormatDescription: CMFormatDescription?
    
    init(delegate: RosyWriterCapturePipelineDelegate, callbackQueue queue: DispatchQueue) {
        recordingOrientation = .portrait
        
        _recordingURL = URL(fileURLWithPath: NSString.path(withComponents: [NSTemporaryDirectory(), "Movie.MOV"]) as String)
        
        _sessionQueue = DispatchQueue(label: "com.apple.sample.capturepipeline.session", attributes: [])
        
        // In a multi-threaded producer consumer system it's generally a good idea to make sure that producers do not get starved of CPU time by their consumers.
        // In this app we start with VideoDataOutput frames on a high priority queue, and downstream consumers use default priority queues.
        // Audio uses a default priority queue because we aren't monitoring it live and just want to get it into the movie.
        // AudioDataOutput can tolerate more latency than VideoDataOutput as its buffers aren't allocated out of a fixed size pool.
        let highQueue = DispatchQueue.global(qos: .userInteractive)
        //### representing "serial" with empty option makes code less readable, Apple should reconsider...
        //### and another issue here: https://bugs.swift.org/browse/SR-1859, Apple, please update the documentation of Dispatch soon.
        _videoDataOutputQueue = DispatchQueue(label: "com.apple.sample.capturepipeline.video", attributes: [], target: highQueue)
//        _videoDataOutputQueue = DispatchQueue(label: "com.apple.sample.capturepipeline.video", attributes: [])
//        _videoDataOutputQueue.setTarget(queue: DispatchQueue.global(qos: .userInteractive))
        
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
        
        _pipelineRunningTask = .invalid
        _delegate = delegate
        _delegateCallbackQueue = queue
        super.init()
    }
    
    deinit {
        
        self.teardownCaptureSession()
        
    }
    
    //MARK: Capture Session
    // These methods are synchronous
    
    func startRunning() {
        _sessionQueue.sync {
            self.setupCaptureSession()
            
            if let captureSession = self._captureSession {
                captureSession.startRunning()
                self._running = true
            }
        }
    }
    
    func stopRunning() {
        _sessionQueue.sync {
            self._running = false
            
            // the captureSessionDidStopRunning method will stop recording if necessary as well, but we do it here so that the last video and audio samples are better aligned
            self.stopRecording() // does nothing if we aren't currently recording
            
            self._captureSession?.stopRunning()
            
            self.captureSessionDidStopRunning()
            
            self.teardownCaptureSession()
        }
    }
    
    enum PipelineError: Error {
        case cannotAddInputVideo
    }
    private func setupCaptureSession() {
        if _captureSession != nil {
            return
        }
        
        _captureSession = AVCaptureSession()
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.captureSessionNotification(_:)), name: nil, object: _captureSession)
        _applicationWillEnterForegroundNotificationObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: UIApplication.shared, queue: nil) {note in
            // Retain self while the capture session is alive by referencing it in this observer block which is tied to the session lifetime
            // Client must stop us running before we can be deallocated
            self.applicationWillEnterForeground()
        }
        
        #if RECORD_AUDIO
            /* Audio */
            let audioDevice = AVCaptureDevice.default(for: .audio)!
            let audioIn = try! AVCaptureDeviceInput(device: audioDevice)
            if _captureSession!.canAddInput(audioIn) {
                _captureSession!.addInput(audioIn)
            }
            
            let audioOut = AVCaptureAudioDataOutput()
            // Put audio on its own queue to ensure that our video processing doesn't cause us to drop audio
            let audioCaptureQueue = DispatchQueue(label: "com.apple.sample.capturepipeline.audio", attributes: [])
            audioOut.setSampleBufferDelegate(self, queue: audioCaptureQueue)
            
            if _captureSession!.canAddOutput(audioOut) {
                _captureSession!.addOutput(audioOut)
            }
            _audioConnection = audioOut.connection(with: AVMediaType.audio)
        #endif // RECORD_AUDIO
        
        /* Video */
        guard let videoDevice = AVCaptureDevice.default(for: AVMediaType.video) else {
            fatalError("AVCaptureDevice of type AVMediaTypeVideo unavailable!")
        }
        do {
            let videoIn = try AVCaptureDeviceInput(device: videoDevice)
            if _captureSession!.canAddInput(videoIn) {
                _captureSession!.addInput(videoIn)
            } else {
                throw PipelineError.cannotAddInputVideo
            }
            _videoDevice = videoDevice
        } catch let videoDeviceError {
            self.handleNonRecoverableCaptureSessionRuntimeError(videoDeviceError)
            return;
        }
        
        let videoOut = AVCaptureVideoDataOutput()
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: _renderer.inputPixelFormat]
        videoOut.setSampleBufferDelegate(self, queue: _videoDataOutputQueue)
        
        // RosyWriter records videos and we prefer not to have any dropped frames in the video recording.
        // By setting alwaysDiscardsLateVideoFrames to NO we ensure that minor fluctuations in system load or in our processing time for a given frame won't cause framedrops.
        // We do however need to ensure that on average we can process frames in realtime.
        // If we were doing preview only we would probably want to set alwaysDiscardsLateVideoFrames to YES.
        videoOut.alwaysDiscardsLateVideoFrames = false
        
        if _captureSession!.canAddOutput(videoOut) {
            _captureSession!.addOutput(videoOut)
        }
        _videoConnection = videoOut.connection(with: AVMediaType.video)
        
        var frameRate: Int32
        var sessionPreset = AVCaptureSession.Preset.high
        var frameDuration = CMTime.invalid
        // For single core systems like iPhone 4 and iPod Touch 4th Generation we use a lower resolution and framerate to maintain real-time performance.
        if ProcessInfo.processInfo.processorCount == 1 {
            if _captureSession!.canSetSessionPreset(AVCaptureSession.Preset.vga640x480) {
                sessionPreset = AVCaptureSession.Preset.vga640x480
            }
            frameRate = 15
        } else {
            #if !USE_OPENGL_RENDERER
                // When using the CPU renderers or the CoreImage renderer we lower the resolution to 720p so that all devices can maintain real-time performance (this is primarily for A5 based devices like iPhone 4s and iPod Touch 5th Generation).
                if _captureSession!.canSetSessionPreset(AVCaptureSession.Preset.hd1280x720) {
                    sessionPreset = AVCaptureSession.Preset.hd1280x720
                }
            #endif // !USE_OPENGL_RENDERER
            
            frameRate = 30
        }
        
        _captureSession!.sessionPreset = sessionPreset
        
        frameDuration = CMTimeMake(value: 1, timescale: frameRate)
        
        do {
            try videoDevice.lockForConfiguration()
            videoDevice.activeVideoMaxFrameDuration = frameDuration
            videoDevice.activeVideoMinFrameDuration = frameDuration
            videoDevice.unlockForConfiguration()
        } catch {
            NSLog("videoDevice lockForConfiguration returned error \(error)")
        }
        
        // Get the recommended compression settings after configuring the session/device.
        #if RECORD_AUDIO
        _audioCompressionSettings = audioOut.recommendedAudioSettingsForAssetWriter(writingTo: AVFileType.mov) as! [String: Any]
        #endif
        _videoCompressionSettings = videoOut.recommendedVideoSettingsForAssetWriter(writingTo: AVFileType.mov)!
        
        _videoBufferOrientation = _videoConnection!.videoOrientation
        
        return
    }
    
    private func teardownCaptureSession() {
        if _captureSession != nil {
            NotificationCenter.default.removeObserver(self, name: nil, object: _captureSession)
            
            NotificationCenter.default.removeObserver(_applicationWillEnterForegroundNotificationObserver!)
            _applicationWillEnterForegroundNotificationObserver = nil
            
            _captureSession = nil
            
            _videoCompressionSettings = [:]
            _audioCompressionSettings = [:]
        }
    }
    
    @objc func captureSessionNotification(_ notification: Notification) {
        _sessionQueue.async {
            
            if notification.name == NSNotification.Name.AVCaptureSessionWasInterrupted {
                NSLog("session interrupted")
                
                self.captureSessionDidStopRunning()
            } else if notification.name == NSNotification.Name.AVCaptureSessionInterruptionEnded {
                NSLog("session interruption ended")
            } else if notification.name == NSNotification.Name.AVCaptureSessionRuntimeError {
                self.captureSessionDidStopRunning()
                
                let error = notification.userInfo![AVCaptureSessionErrorKey]! as! NSError
                /*if error.code == AVError.Code.deviceIsNotAvailableInBackground.rawValue {
                    NSLog("device not available in background")
                    
                    // Since we can't resume running while in the background we need to remember this for next time we come to the foreground
                    if self._running {
                        self._startCaptureSessionOnEnteringForeground = true
                    }
                } else*/ if error.code == AVError.Code.mediaServicesWereReset.rawValue {
                    NSLog("media services were reset")
                    self.handleRecoverableCaptureSessionRuntimeError(error)
                } else {
                    self.handleNonRecoverableCaptureSessionRuntimeError(error)
                }
            } else if notification.name == NSNotification.Name.AVCaptureSessionDidStartRunning {
                NSLog("session started running")
            } else if notification.name == NSNotification.Name.AVCaptureSessionDidStopRunning {
                NSLog("session stopped running")
            }
        }
    }
    
    private func handleRecoverableCaptureSessionRuntimeError(_ error: Error) {
        if _running {
            _captureSession?.startRunning()
        }
    }
    
    private func handleNonRecoverableCaptureSessionRuntimeError(_ error: Error) {
        NSLog("fatal runtime error \(error), code \((error as NSError).code)")
        
        _running = false
        self.teardownCaptureSession()
        
        self.invokeDelegateCallbackAsync {
            self._delegate?.capturePipeline(self, didStopRunningWithError: error)
        }
    }
    
    private func captureSessionDidStopRunning() {
        self.stopRecording()
        self.teardownCaptureSession()
    }
    
    private func applicationWillEnterForeground() {
        NSLog("-[%@ %@] called", NSStringFromClass(type(of: self)), #function)
        
        _sessionQueue.sync {
            if self._startCaptureSessionOnEnteringForeground {
                NSLog("-[%@ %@] manually restarting session", NSStringFromClass(type(of: self)), #function)
                
                self._startCaptureSessionOnEnteringForeground = false
                if self._running {
                    self._captureSession?.startRunning()
                }
            }
        }
    }
    
    //MARK: Capture Pipeline
    
    private func setupVideoPipelineWithInputFormatDescription(_ inputFormatDescription: CMFormatDescription) {
        NSLog("-[%@ %@] called", NSStringFromClass(type(of: self)), #function)
        
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
        
        NSLog("-[%@ %@] called", NSStringFromClass(type(of: self)), #function)
        
        _videoDataOutputQueue.sync {
            if self.outputVideoFormatDescription == nil {
                return
            }
            
            self.outputVideoFormatDescription = nil
            self._renderer.reset()
            self.currentPreviewPixelBuffer = nil
            
            NSLog("-[%@ %@] finished teardown", NSStringFromClass(type(of: self)), #function)
            
            self.videoPipelineDidFinishRunning()
        }
    }
    
    private func videoPipelineWillStartRunning() {
        NSLog("-[%@ %@] called", NSStringFromClass(type(of: self)), #function)
        
        assert(_pipelineRunningTask == .invalid, "should not have a background task active before the video pipeline starts running")
        
        _pipelineRunningTask = UIApplication.shared.beginBackgroundTask (expirationHandler: {
            NSLog("video capture pipeline background task expired")
        })
    }
    
    private func videoPipelineDidFinishRunning() {
        NSLog("-[%@ %@] called", NSStringFromClass(type(of: self)), #function)
        
        assert(_pipelineRunningTask != .invalid, "should have a background task active when the video pipeline finishes running")
        
        UIApplication.shared.endBackgroundTask(_pipelineRunningTask)
        _pipelineRunningTask = .invalid
    }
    
    // call under @synchronized( self )
    func videoPipelineDidRunOutOfBuffers() {
        // We have run out of buffers.
        // Tell the delegate so that it can flush any cached buffers.
        self.invokeDelegateCallbackAsync {
            self._delegate?.capturePipelineDidRunOutOfPreviewBuffers(self)
        }
    }
    
    var /*atomic*/ renderingEnabled: Bool {
        set {
            synchronized(_renderer) {
                self._renderingEnabled = newValue
            }
        }
        
        get {
            var myRenderingEnabled = false
            synchronized(_renderer) {
                myRenderingEnabled = self._renderingEnabled
            }
            return myRenderingEnabled
        }
    }
    
    func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
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
                if _recordingStatus == .recording {
                    self._recorder.appendAudioSampleBuffer(sampleBuffer)
                }
            }
        }
    }
    
    private func renderVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
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
        
        if let renderedPixelBuffer = renderedPixelBuffer {
            synchronized(self) {
                self.outputPreviewPixelBuffer(renderedPixelBuffer)
                
                if _recordingStatus == .recording {
                    self._recorder.appendVideoPixelBuffer(renderedPixelBuffer, withPresentationTime: timestamp)
                }
            }
        } else {
            self.videoPipelineDidRunOutOfBuffers()
        }
    }
    
    // call under @synchronized( self )
    private func outputPreviewPixelBuffer(_ previewPixelBuffer: CVPixelBuffer) {
        // Keep preview latency low by dropping stale frames that have not been picked up by the delegate yet
        // Note that access to currentPreviewPixelBuffer is protected by the @synchronized lock
        self.currentPreviewPixelBuffer = previewPixelBuffer
        
        self.invokeDelegateCallbackAsync {
            
            var currentPreviewPixelBuffer: CVPixelBuffer? = nil
            synchronized(self) {
                currentPreviewPixelBuffer = self.currentPreviewPixelBuffer
                if currentPreviewPixelBuffer != nil {
                    self.currentPreviewPixelBuffer = nil
                }
            }
            
            if currentPreviewPixelBuffer != nil {
                self._delegate?.capturePipeline(self, previewPixelBufferReadyForDisplay: currentPreviewPixelBuffer!)
            }
        }
    }
    
    //MARK: Recording
    // Must be running before starting recording
    // These methods are asynchronous, see the recording delegate callbacks
    
    func startRecording() {
        synchronized(self) {
            if _recordingStatus != .idle {
                fatalError("Already recording")
            }
            
            self.transitionToRecordingStatus(.startingRecording, error: nil)
        }
        
        let callbackQueue = DispatchQueue(label: "com.apple.sample.capturepipeline.recordercallback", attributes: []); // guarantee ordering of callbacks with a serial queue
        let recorder = MovieRecorder(url: _recordingURL, delegate: self, callbackQueue: callbackQueue)
        
        #if RECORD_AUDIO
            recorder.addAudioTrackWithSourceFormatDescription(self.outputAudioFormatDescription!, settings: _audioCompressionSettings)
        #endif // RECORD_AUDIO
        
        // Front camera recording shouldn't be mirrored
        let videoTransform = self.transformFromVideoBufferOrientationToOrientation(self.recordingOrientation, withAutoMirroring: false)
        
        recorder.addVideoTrackWithSourceFormatDescription(self.outputVideoFormatDescription!, transform: videoTransform, settings: _videoCompressionSettings)
        
        _recorder = recorder
        
        // asynchronous, will call us back with recorderDidFinishPreparing: or recorder:didFailWithError: when done
        recorder.prepareToRecord()
    }
    
    func stopRecording() {
        let returnFlag: Bool = synchronized(self) {
            if _recordingStatus != .recording {
                return true
            }
            
            self.transitionToRecordingStatus(.stoppingRecording, error: nil)
            return false
        }
        if returnFlag {return}
        
        _recorder.finishRecording() // asynchronous, will call us back with recorderDidFinishRecording: or recorder:didFailWithError: when done
    }
    
    //MARK: MovieRecorder Delegate
    
    func movieRecorderDidFinishPreparing(_ recorder: MovieRecorder) {
        synchronized(self) {
            if _recordingStatus != .startingRecording {
                fatalError("Expected to be in StartingRecording state")
            }
            self.transitionToRecordingStatus(.recording, error: nil)
        }
    }
    
    func movieRecorder(_ recorder: MovieRecorder, didFailWithError error: Error) {
        synchronized(self) {
            _recorder = nil
            self.transitionToRecordingStatus(.idle, error: error)
        }
    }
    
    func movieRecorderDidFinishRecording(_ recorder: MovieRecorder) {
        synchronized(self) {
            if _recordingStatus != .stoppingRecording {
                fatalError("Expected to be in StoppingRecording state")
            }
            
            // No state transition, we are still in the process of stopping.
            // We will be stopped once we save to the assets library.
        }
        
        _recorder = nil
        
        let phLibrary = PHPhotoLibrary.shared()
        phLibrary.performChanges({
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: self._recordingURL)
        }, completionHandler: {success, error in
            
            do {
                try FileManager.default.removeItem(at: self._recordingURL)
            } catch _ {
            }
            
            synchronized(self) {
                if self._recordingStatus != .stoppingRecording {
                    fatalError("Expected to be in StoppingRecording state")
                }
                self.transitionToRecordingStatus(.idle, error: error)
            }
        })
    }
    
    //MARK: Recording State Machine
    
    // call under @synchonized( self )
    private func transitionToRecordingStatus(_ newStatus: RosyWriterRecordingStatus, error: Error?) {
        let oldStatus = _recordingStatus
        _recordingStatus = newStatus
        
        #if LOG_STATUS_TRANSITIONS
            NSLog("RosyWriterCapturePipeline recording state transition: %@->%@", oldStatus.description, newStatus.description)
        #endif
        
        if newStatus != oldStatus {
            var delegateCallbackBlock: (()->Void)? = nil;
            
            if let error = error, newStatus == .idle {
                delegateCallbackBlock = {self._delegate?.capturePipeline(self, recordingDidFailWithError: error)}
            } else {
                // only the above delegate method takes an error
                if oldStatus == .startingRecording && newStatus == .recording {
                    delegateCallbackBlock = {self._delegate?.capturePipelineRecordingDidStart(self)}
                } else if oldStatus == .recording && newStatus == .stoppingRecording {
                    delegateCallbackBlock = {self._delegate?.capturePipelineRecordingWillStop(self)}
                } else if oldStatus == .stoppingRecording && newStatus == .idle {
                    delegateCallbackBlock = {self._delegate?.capturePipelineRecordingDidStop(self)}
                }
            }
            
            if let delegateCallbackBlock = delegateCallbackBlock {
                self.invokeDelegateCallbackAsync {
                        delegateCallbackBlock()
                }
            }
        }
    }
    
    //MARK: Utilities
    
    private func invokeDelegateCallbackAsync(_ callbackBlock: @escaping ()->Void) {
    	_delegateCallbackQueue?.async {
            autoreleasepool {
                callbackBlock()
            }
    	}
    }
    
    // Auto mirroring: Front camera is mirrored; back camera isn't
    // only valid after startRunning has been called
    func transformFromVideoBufferOrientationToOrientation(_ orientation: AVCaptureVideoOrientation, withAutoMirroring mirror: Bool) -> CGAffineTransform {
        var transform = CGAffineTransform.identity
        
        // Calculate offsets from an arbitrary reference orientation (portrait)
        let orientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation(orientation)
        let videoOrientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation(_videoBufferOrientation)
        
        // Find the difference in angle between the desired orientation and the video orientation
        let angleOffset = orientationAngleOffset - videoOrientationAngleOffset
        transform = CGAffineTransform(rotationAngle: angleOffset)
        
        if _videoDevice!.position == .front {
            if mirror {
                transform = transform.scaledBy(x: -1, y: 1)
            } else {
                if UIInterfaceOrientation(rawValue: orientation.rawValue)!.isPortrait {
                    transform = transform.rotated(by: .pi)
                }
            }
        }
        
        return transform
    }
    
    private final func angleOffsetFromPortraitOrientationToOrientation(_ orientation: AVCaptureVideoOrientation) -> CGFloat {
        var angle: CGFloat = 0.0
        
        switch orientation {
        case .portrait:
            angle = 0.0
        case .portraitUpsideDown:
            angle = .pi
        case .landscapeRight:
            angle = -CGFloat.pi/2
        case .landscapeLeft:
            angle = .pi/2
        @unknown default:
            break
        }
        
        return angle
    }
    
    private func calculateFramerateAtTimestamp(_ timestamp: CMTime) {
        _previousSecondTimestamps.append(timestamp)
        
        let oneSecond = CMTimeMake(value: 1, timescale: 1)
        let oneSecondAgo = CMTimeSubtract(timestamp, oneSecond)
        
        while _previousSecondTimestamps[0] < oneSecondAgo {
            _previousSecondTimestamps.remove(at: 0)
        }
        
        if _previousSecondTimestamps.count > 1 {
            let duration: Double = CMTimeGetSeconds(CMTimeSubtract(_previousSecondTimestamps.last!, _previousSecondTimestamps[0]))
            let newRate = Float(_previousSecondTimestamps.count - 1) / duration.f
            self.videoFrameRate = newRate
        }
    }
    
}
