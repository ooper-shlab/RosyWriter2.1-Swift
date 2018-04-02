//
//  RosyWriterViewController.swift
//  RosyWriter
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/1/18.
//
//
//
/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information

 Abstract:
 View controller for camera interface
 */


import UIKit
import AVFoundation

@objc(RosyWriterViewController)
class RosyWriterViewController: UIViewController, RosyWriterCapturePipelineDelegate {
    
    private var _addedObservers: Bool = false
    private var _recording: Bool = false
    private var _backgroundRecordingID: UIBackgroundTaskIdentifier = 0
    private var _allowedToUseGPU: Bool = false
    
    private var _labelTimer: Timer?
    private var _previewView: OpenGLPixelBufferView?
    private var _capturePipeline: RosyWriterCapturePipeline!
    
    @IBOutlet private var recordButton: UIBarButtonItem!
    @IBOutlet private var framerateLabel: UILabel!
    @IBOutlet private var dimensionsLabel: UILabel!
    
    deinit {
        if _addedObservers {
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIApplicationDidEnterBackground, object: UIApplication.shared)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIApplicationWillEnterForeground, object: UIApplication.shared)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIDeviceOrientationDidChange, object: UIDevice.current)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        
    }
    
    //MARK: - View lifecycle
    
    @objc func applicationDidEnterBackground() {
        // Avoid using the GPU in the background
        _allowedToUseGPU = false
        _capturePipeline?.renderingEnabled = false
        
        _capturePipeline?.stopRecording() // a no-op if we aren't recording
        
        // We reset the OpenGLPixelBufferView to ensure all resources have been cleared when going to the background.
        _previewView?.reset()
    }
    
    @objc func applicationWillEnterForeground() {
        _allowedToUseGPU = true
        _capturePipeline?.renderingEnabled = true
    }
    
    override func viewDidLoad() {
        _capturePipeline = RosyWriterCapturePipeline(delegate: self, callbackQueue: DispatchQueue.main)
        
        NotificationCenter.default.addObserver(self,
            selector: #selector(self.applicationDidEnterBackground),
            name: NSNotification.Name.UIApplicationDidEnterBackground,
            object: UIApplication.shared)
        NotificationCenter.default.addObserver(self,
            selector: #selector(self.applicationWillEnterForeground),
            name: NSNotification.Name.UIApplicationWillEnterForeground,
            object: UIApplication.shared)
        NotificationCenter.default.addObserver(self,
            selector: #selector(self.deviceOrientationDidChange),
            name: NSNotification.Name.UIDeviceOrientationDidChange,
            object: UIDevice.current)
        
        // Keep track of changes to the device orientation so we can update the capture pipeline
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        _addedObservers = true
        
        // the willEnterForeground and didEnterBackground notifications are subsequently used to update _allowedToUseGPU
        _allowedToUseGPU = (UIApplication.shared.applicationState != .background)
        _capturePipeline.renderingEnabled = _allowedToUseGPU
        
        super.viewDidLoad()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        _capturePipeline.startRunning()
        
        _labelTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(self.updateLabels), userInfo: nil, repeats: true)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        _labelTimer?.invalidate()
        _labelTimer = nil
        
        _capturePipeline.stopRunning()
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return UIInterfaceOrientationMask.portrait
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    //MARK: - UI
    
    @IBAction func toggleRecording(_: Any) {
        if _recording {
            _capturePipeline.stopRecording()
        } else {
            // Disable the idle timer while recording
            UIApplication.shared.isIdleTimerDisabled = true
            
            // Make sure we have time to finish saving the movie if the app is backgrounded during recording
            if UIDevice.current.isMultitaskingSupported {
                _backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: {})
            }
            
            self.recordButton.isEnabled = false; // re-enabled once recording has finished starting
            self.recordButton.title = "Stop"
            
            _capturePipeline.startRecording()
            
            _recording = true
        }
    }
    
    private func recordingStopped() {
        _recording = false
        self.recordButton.isEnabled = true
        self.recordButton.title = "Record"
        
        UIApplication.shared.isIdleTimerDisabled = false
        
        UIApplication.shared.endBackgroundTask(_backgroundRecordingID)
        _backgroundRecordingID = UIBackgroundTaskInvalid
    }
    
    private func setupPreviewView() {
        // Set up GL view
        _previewView = OpenGLPixelBufferView(frame: CGRect.zero)
        _previewView!.autoresizingMask = [UIViewAutoresizing.flexibleHeight, UIViewAutoresizing.flexibleWidth]
        
        let currentInterfaceOrientation = UIApplication.shared.statusBarOrientation
        _previewView!.transform = _capturePipeline.transformFromVideoBufferOrientationToOrientation(AVCaptureVideoOrientation(rawValue: currentInterfaceOrientation.rawValue)!, withAutoMirroring: true) // Front camera preview should be mirrored
        
        self.view.insertSubview(_previewView!, at: 0)
        var bounds = CGRect.zero
        bounds.size = self.view.convert(self.view.bounds, to: _previewView).size
        _previewView!.bounds = bounds
        _previewView!.center = CGPoint(x: self.view.bounds.size.width/2.0, y: self.view.bounds.size.height/2.0)
    }
    
    @objc func deviceOrientationDidChange() {
        let deviceOrientation = UIDevice.current.orientation
        
        // Update recording orientation if device changes to portrait or landscape orientation (but not face up/down)
        if UIDeviceOrientationIsPortrait(deviceOrientation) || UIDeviceOrientationIsLandscape(deviceOrientation) {
            _capturePipeline.recordingOrientation = AVCaptureVideoOrientation(rawValue: deviceOrientation.rawValue)!
        }
    }
    
    @objc func updateLabels() {
        let frameRateString = "\(Int(roundf(_capturePipeline.videoFrameRate))) FPS"
        self.framerateLabel.text = frameRateString
        
        let dimensionsString = "\(_capturePipeline.videoDimensions.width) x \(_capturePipeline.videoDimensions.height)"
        self.dimensionsLabel.text = dimensionsString
    }
    
    private func showError(_ error: Error) {
        let message = (error as NSError).localizedFailureReason
        if #available(iOS 8.0, *) {
            let alert = UIAlertController(title: error.localizedDescription, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            self.present(alert, animated: true, completion: nil)
        } else {
            let alertView = UIAlertView(title: error.localizedDescription,
                message: message,
                delegate: nil,
                cancelButtonTitle: "OK")
            alertView.show()
        }
    }
    
    //MARK: - RosyWriterCapturePipelineDelegate
    
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, didStopRunningWithError error: Error) {
        self.showError(error)
        
        self.recordButton.isEnabled = false
    }
    
    // Preview
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, previewPixelBufferReadyForDisplay previewPixelBuffer: CVPixelBuffer) {
        if !_allowedToUseGPU {
            return
        }
        if _previewView == nil {
            self.setupPreviewView()
        }
        
        _previewView!.displayPixelBuffer(previewPixelBuffer)
    }
    
    func capturePipelineDidRunOutOfPreviewBuffers(_ capturePipeline: RosyWriterCapturePipeline) {
        if _allowedToUseGPU {
            _previewView?.flushPixelBufferCache()
        }
    }
    
    // Recording
    func capturePipelineRecordingDidStart(_ capturePipeline: RosyWriterCapturePipeline) {
        self.recordButton.isEnabled = true
    }
    
    func capturePipelineRecordingWillStop(_ capturePipeline: RosyWriterCapturePipeline) {
        // Disable record button until we are ready to start another recording
        self.recordButton.isEnabled = false
        self.recordButton.title = "Record"
    }
    
    func capturePipelineRecordingDidStop(_ capturePipeline: RosyWriterCapturePipeline) {
        self.recordingStopped()
    }
    
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, recordingDidFailWithError error: Error) {
        self.recordingStopped()
        self.showError(error)
    }
    
}
