//
//  RosyWriterViewController.swift
//  RosyWriter
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/1/18.
//
//
//
/*
     File: RosyWriterViewController.h
     File: RosyWriterViewController.m
 Abstract: View controller for camera interface
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

@objc(RosyWriterViewController)
class RosyWriterViewController: UIViewController, RosyWriterCapturePipelineDelegate {
    
    private var _addedObservers: Bool = false
    private var _recording: Bool = false
    private var _backgroundRecordingID: UIBackgroundTaskIdentifier = 0
    private var _allowedToUseGPU: Bool = false
    
    @IBOutlet private var recordButton: UIBarButtonItem!
    @IBOutlet private var framerateLabel: UILabel!
    @IBOutlet private var dimensionsLabel: UILabel!
    private var labelTimer: Timer?
    private var previewView: OpenGLPixelBufferView?
    private var capturePipeline: RosyWriterCapturePipeline!
    
    deinit {
        if _addedObservers {
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIApplicationDidEnterBackground, object: UIApplication.shared)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIApplicationWillEnterForeground, object: UIApplication.shared)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIDeviceOrientationDidChange, object: UIDevice.current)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        
    }
    
    //MARK: - View lifecycle
    
    func applicationDidEnterBackground() {
        // Avoid using the GPU in the background
        _allowedToUseGPU = false
        self.capturePipeline?.renderingEnabled = false
        
        self.capturePipeline?.stopRecording() // no-op if we aren't recording
        
        // We reset the OpenGLPixelBufferView to ensure all resources have been clear when going to the background.
        self.previewView?.reset()
    }
    
    func applicationWillEnterForeground() {
        _allowedToUseGPU = true
        self.capturePipeline?.renderingEnabled = true
    }
    
    override func viewDidLoad() {
        self.capturePipeline = RosyWriterCapturePipeline()
        self.capturePipeline.setDelegate(self, callbackQueue: DispatchQueue.main)
        
        NotificationCenter.default.addObserver(self,
            selector: #selector(RosyWriterViewController.applicationDidEnterBackground),
            name: NSNotification.Name.UIApplicationDidEnterBackground,
            object: UIApplication.shared)
        NotificationCenter.default.addObserver(self,
            selector: #selector(RosyWriterViewController.applicationWillEnterForeground),
            name: NSNotification.Name.UIApplicationWillEnterForeground,
            object: UIApplication.shared)
        NotificationCenter.default.addObserver(self,
            selector: #selector(RosyWriterViewController.deviceOrientationDidChange),
            name: NSNotification.Name.UIDeviceOrientationDidChange,
            object: UIDevice.current)
        
        // Keep track of changes to the device orientation so we can update the capture pipeline
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        _addedObservers = true
        
        // the willEnterForeground and didEnterBackground notifications are subsequently used to update _allowedToUseGPU
        _allowedToUseGPU = (UIApplication.shared.applicationState != .background)
        self.capturePipeline.renderingEnabled = _allowedToUseGPU
        
        super.viewDidLoad()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        self.capturePipeline.startRunning()
        
        self.labelTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(RosyWriterViewController.updateLabels), userInfo: nil, repeats: true)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        self.labelTimer?.invalidate()
        self.labelTimer = nil
        
        self.capturePipeline.stopRunning()
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return UIInterfaceOrientationMask.portrait
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    //MARK: - UI
    
    @IBAction func toggleRecording(_: AnyObject) {
        if _recording {
            self.capturePipeline.stopRecording()
        } else {
            // Disable the idle timer while recording
            UIApplication.shared.isIdleTimerDisabled = true
            
            // Make sure we have time to finish saving the movie if the app is backgrounded during recording
            if UIDevice.current.isMultitaskingSupported {
                _backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: {})
            }
            
            self.recordButton.isEnabled = false; // re-enabled once recording has finished starting
            self.recordButton.title = "Stop"
            
            self.capturePipeline.startRecording()
            
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
        self.previewView = OpenGLPixelBufferView(frame: CGRect.zero)
        self.previewView!.autoresizingMask = [UIViewAutoresizing.flexibleHeight, UIViewAutoresizing.flexibleWidth]
        
        let currentInterfaceOrientation = UIApplication.shared.statusBarOrientation
        self.previewView!.transform = self.capturePipeline.transformFromVideoBufferOrientationToOrientation(AVCaptureVideoOrientation(rawValue: currentInterfaceOrientation.rawValue)!, withAutoMirroring: true) // Front camera preview should be mirrored
        
        self.view.insertSubview(self.previewView!, at: 0)
        var bounds = CGRect.zero
        bounds.size = self.view.convert(self.view.bounds, to: self.previewView).size
        self.previewView!.bounds = bounds
        self.previewView!.center = CGPoint(x: self.view.bounds.size.width/2.0, y: self.view.bounds.size.height/2.0)
    }
    
    func deviceOrientationDidChange() {
        let deviceOrientation = UIDevice.current.orientation
        
        // Update recording orientation if device changes to portrait or landscape orientation (but not face up/down)
        if UIDeviceOrientationIsPortrait(deviceOrientation) || UIDeviceOrientationIsLandscape(deviceOrientation) {
            self.capturePipeline.recordingOrientation = AVCaptureVideoOrientation(rawValue: deviceOrientation.rawValue)!
        }
    }
    
    func updateLabels() {
        let frameRateString = "\(Int(roundf(self.capturePipeline.videoFrameRate))) FPS"
        self.framerateLabel.text = frameRateString
        
        let dimensionsString = "\(self.capturePipeline.videoDimensions.width) x \(self.capturePipeline.videoDimensions.height)"
        self.dimensionsLabel.text = dimensionsString
    }
    
    private func showError(_ error: NSError) {
        if #available(iOS 8.0, *) {
            let alert = UIAlertController(title: error.localizedDescription, message: error.localizedFailureReason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            self.present(alert, animated: true, completion: nil)
        } else {
            let alertView = UIAlertView(title: error.localizedDescription,
                message: error.localizedFailureReason,
                delegate: nil,
                cancelButtonTitle: "OK")
            alertView.show()
        }
    }
    
    //MARK: - RosyWriterCapturePipelineDelegate
    
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, didStopRunningWithError error: NSError) {
        self.showError(error)
        
        self.recordButton.isEnabled = false
    }
    
    // Preview
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, previewPixelBufferReadyForDisplay previewPixelBuffer: CVPixelBuffer) {
        if !_allowedToUseGPU {
            return
        }
        if self.previewView == nil {
            self.setupPreviewView()
        }
        
        self.previewView!.displayPixelBuffer(previewPixelBuffer)
    }
    
    func capturePipelineDidRunOutOfPreviewBuffers(_ capturePipeline: RosyWriterCapturePipeline) {
        if _allowedToUseGPU {
            self.previewView?.flushPixelBufferCache()
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
    
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, recordingDidFailWithError error: NSError) {
        self.recordingStopped()
        self.showError(error)
    }
    
}
