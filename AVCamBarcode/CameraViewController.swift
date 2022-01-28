/*
See LICENSE folder for this sample’s licensing information.

Abstract:
The view controller for the camera interface.
*/

import UIKit
import AVFoundation
import SafariServices

class CameraViewController: UIViewController,
                            AVCaptureMetadataOutputObjectsDelegate {
    
	// MARK: View Controller Life Cycle
	
	override func viewDidLoad() {
		super.viewDidLoad()
		
		// The UI is disabled, it's enabled only if the session starts running.
		cameraButton.isEnabled = false
		
		// Set up the video preview view.
		previewView.session = session
		
		/*
         Check video authorization status. The app requires video access, but
         audio access is optional. If the user denies audio access, audio isn't
         recorded.
		*/
		switch AVCaptureDevice.authorizationStatus(for: .video) {
		case .authorized:
			// The user has previously granted access to the camera.
			break
		
		case .notDetermined:
			/*
             The app hasn't requested permission. Suspend the session queue to
             delay session setup until the access request has completed.
			*/
			sessionQueue.suspend()
			AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
				if !granted {
					self.setupResult = .notAuthorized
				}
				self.sessionQueue.resume()
			})
	
		default:
			// The user has previously denied access.
			setupResult = .notAuthorized
		}
		
		/*
         Set up the capture session.
         In general, it is not safe to mutate an `AVCaptureSession` or any of its
         inputs, outputs, or connections from multiple threads at the same time.
		
         Why not do all this on the main queue?
         Because `AVCaptureSession.startRunning()` is a blocking call, which can
         take a long time. Move the dispatch session setup to the sessionQueue so
         that the main queue isn't blocked, which keeps the UI responsive.
		*/
		sessionQueue.async {
			self.configureSession()
		}
	}
	
	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		
		sessionQueue.async {
			switch self.setupResult {
			case .success:
				// Set up observers and start the session only if setup succeeded.
				self.addObservers()
				self.session.startRunning()
				self.isSessionRunning = self.session.isRunning
			
			case .notAuthorized:
				DispatchQueue.main.async {
					let changePrivatySetting = "AVCamBarcode doesn't have permission to use the camera, please change privacy settings"
					let message = NSLocalizedString(changePrivatySetting, comment: "Alert message when the user has denied access to the camera")
					let	alertController = UIAlertController(title: "AVCamBarcode", message: message, preferredStyle: .alert)
					alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil))
					alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings",
																					 comment: "Alert button to open Settings"),
																					 style: .`default`, handler: { _ in
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
					}))
					
					self.present(alertController, animated: true, completion: nil)
				}
			
			case .configurationFailed:
				DispatchQueue.main.async {
					let alertMsg = "Unable to capture media"
					let message = NSLocalizedString(alertMsg, comment: "Alert message when something goes wrong during capture session configuration")
					let alertController = UIAlertController(title: "AVCamBarcode", message: message, preferredStyle: .alert)
					alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil))
					
					self.present(alertController, animated: true, completion: nil)
				}
			}
		}
	}
	
	override func viewWillDisappear(_ animated: Bool) {
		sessionQueue.async {
			if self.setupResult == .success {
				self.session.stopRunning()
				self.isSessionRunning = self.session.isRunning
				self.removeObservers()
			}
		}
		
		super.viewWillDisappear(animated)
	}
	
	override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)
		
		if let videoPreviewLayerConnection = previewView.videoPreviewLayer.connection {
			let deviceOrientation = UIDevice.current.orientation
			guard let newVideoOrientation = AVCaptureVideoOrientation(deviceOrientation: deviceOrientation),
				deviceOrientation.isPortrait || deviceOrientation.isLandscape else {
				return
			}
			
			videoPreviewLayerConnection.videoOrientation = newVideoOrientation
            
            // Remove the old metadata object overlays.
            self.removeMetadataObjectOverlayLayers()
		}
	}
	
	var windowOrientation: UIInterfaceOrientation {
		return view.window?.windowScene?.interfaceOrientation ?? .unknown
	}
	
	// MARK: Session Management
	
	private enum SessionSetupResult {
		case success
		case notAuthorized
		case configurationFailed
	}
	
	private let session = AVCaptureSession()
	
	private var isSessionRunning = false
	
    // A session for communicating with the session and other session objects on this queue.
	private let sessionQueue = DispatchQueue(label: "session queue")
	
	private var setupResult: SessionSetupResult = .success
	
	var videoDeviceInput: AVCaptureDeviceInput!
	
	@IBOutlet private var previewView: PreviewView!
	
	// Call this method on the session queue.
	private func configureSession() {
		if self.setupResult != .success {
			return
		}
		
		session.beginConfiguration()
		
		// Add video input.
		do {
			let defaultVideoDevice: AVCaptureDevice?
			
			// Choose the back wide angle camera if available, otherwise default to the front wide angle camera.
			if let backCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
				defaultVideoDevice = backCameraDevice
			} else if let frontCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
				// Default to the front wide angle camera if the back wide angle camera is unavailable.
				defaultVideoDevice = frontCameraDevice
			} else {
				defaultVideoDevice = nil
			}
			
			guard let videoDevice = defaultVideoDevice else {
				print("Could not get video device")
				setupResult = .configurationFailed
				session.commitConfiguration()
				return
			}
			
			let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
			
			if session.canAddInput(videoDeviceInput) {
				session.addInput(videoDeviceInput)
				self.videoDeviceInput = videoDeviceInput
				
				DispatchQueue.main.async {
					/*
                     Dispatch to the main queue because `AVCaptureVideoPreviewLayer` is
                     the backing layer for `PreviewView` and `UIView` can only change on the main thread.
                     Note: As an exception to the above rule, it is not necessary
                     to serialize video orientation changes on the `AVCaptureVideoPreviewLayer`’s
                     connection with other session manipulation.
					
                     Use the window orientation as the initial video orientation.
                     Subsequent orientation changes are handled by
                     `CameraViewController.viewWillTransition(to:with:)`.
					*/
					var initialVideoOrientation: AVCaptureVideoOrientation = .portrait
					if self.windowOrientation != .unknown {
						if let videoOrientation = AVCaptureVideoOrientation(interfaceOrientation: self.windowOrientation) {
							initialVideoOrientation = videoOrientation
						}
					}

					self.previewView.videoPreviewLayer.connection!.videoOrientation = initialVideoOrientation
				}
			} else {
				print("Could not add video device input to the session")
				setupResult = .configurationFailed
				session.commitConfiguration()
				return
			}
		} catch {
			print("Could not create video device input: \(error)")
			setupResult = .configurationFailed
			session.commitConfiguration()
			return
		}
		
		// Add metadata output.
		if session.canAddOutput(metadataOutput) {
			session.addOutput(metadataOutput)
			
			// Set this view controller as the delegate for metadata objects.
			metadataOutput.setMetadataObjectsDelegate(self, queue: metadataObjectsQueue)
			metadataOutput.metadataObjectTypes = metadataOutput.availableMetadataObjectTypes // Use all metadata object types by default.
			
			// Set rectangle of interest as 100% of the view.
			metadataOutput.rectOfInterest = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
		} else {
			print("Could not add metadata output to the session")
			setupResult = .configurationFailed
			session.commitConfiguration()
			return
		}
		
		session.commitConfiguration()
	}

	private let metadataOutput = AVCaptureMetadataOutput()
	
	private let metadataObjectsQueue = DispatchQueue(label: "metadata objects queue", attributes: [], target: nil)
	
	// MARK: Device Configuration
	
	@IBOutlet private var cameraButton: UIButton!
	
	@IBOutlet private var cameraUnavailableLabel: UILabel!
	
	private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
	
	@IBAction private func changeCamera() {
		cameraButton.isEnabled = false
		
		// Remove the metadata overlay layers, if any.
		removeMetadataObjectOverlayLayers()
		
		DispatchQueue.main.async {
			let currentVideoDevice = self.videoDeviceInput.device
			let currentPosition = currentVideoDevice.position
			
			let preferredPosition: AVCaptureDevice.Position
			
			switch currentPosition {
			case .unspecified, .front:
				preferredPosition = .back
			
			case .back:
				preferredPosition = .front
            @unknown default:
                fatalError("Unknown device position.")
            }
			
			let devices = self.videoDeviceDiscoverySession.devices
			let newVideoDevice = devices.first(where: { $0.position == preferredPosition })
			
			if let videoDevice = newVideoDevice {
				do {
					let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
					
					self.session.beginConfiguration()
					
					/*
                     Remove the existing device input first because using the
                     front and back camera simultaneously is not supported.
                     */
					self.session.removeInput(self.videoDeviceInput)
					
					/*
                     When changing devices, a session present available on one
                     device may not be available on another. To allow the user
                     to switch devices, save the previous session preset, set
                     the default session preset (high), and attempt to restore
                     it after selecting the new video device. For example, the
                     4K session preset supports the back device only on iPhone 6s
                     and iPhone 6s Plus. As a result, the session doesn't
                     allow for adding a video device that doesn't support the
                     current session preset.
					*/
					let previousSessionPreset = self.session.sessionPreset
					self.session.sessionPreset = .high
					
					if self.session.canAddInput(videoDeviceInput) {
						self.session.addInput(videoDeviceInput)
						self.videoDeviceInput = videoDeviceInput
					} else {
						self.session.addInput(self.videoDeviceInput)
					}
					
					// Restore the previous session preset.
					if self.session.canSetSessionPreset(previousSessionPreset) {
						self.session.sessionPreset = previousSessionPreset
					}
					
					self.session.commitConfiguration()
				} catch {
					print("Error occured while creating video device input: \(error)")
				}
			}
			
			DispatchQueue.main.async {
				self.cameraButton.isEnabled = true
			}
		}
	}
	
	// MARK: KVO and Notifications
	
	private var keyValueObservations = [NSKeyValueObservation]()
	
	private func addObservers() {
		var keyValueObservation: NSKeyValueObservation
		
		keyValueObservation = session.observe(\.isRunning, options: .new) { _, change in
			guard let isSessionRunning = change.newValue else { return }
			
			DispatchQueue.main.async {
				self.cameraButton.isEnabled = isSessionRunning && self.videoDeviceDiscoverySession.devices.count > 1
				
				/*
                 After the session stops running, remove the metadata object
                 overlays, if any, so that if the view appears again, the app
                 doesn't display the previous overlays.
				*/
				if !isSessionRunning {
					self.removeMetadataObjectOverlayLayers()
				}
			}
		}
		keyValueObservations.append(keyValueObservation)
	
		let notificationCenter = NotificationCenter.default
		
		notificationCenter.addObserver(self, selector: #selector(sessionRuntimeError), name: .AVCaptureSessionRuntimeError, object: session)
		
		/*
         A session can run only when the app is full screen. The system interrupts
         an app in a multi-app layout, introduced in iOS 9. See the documentation of
         `AVCaptureSessionInterruptionReason`. Add observers to handle these
         interruptions and show a preview paused message. See the documentation
         of `AVCaptureSessionWasInterruptedNotification` for other interruption reasons.
		*/
		notificationCenter.addObserver(self, selector: #selector(sessionWasInterrupted), name: .AVCaptureSessionWasInterrupted, object: session)
		notificationCenter.addObserver(self, selector: #selector(sessionInterruptionEnded), name: .AVCaptureSessionInterruptionEnded, object: session)
	}
	
	private func removeObservers() {
		NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionInterruptionEnded, object: session)
		NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionWasInterrupted, object: session)
		NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)
		
		for keyValueObservation in keyValueObservations {
			keyValueObservation.invalidate()
		}
		keyValueObservations.removeAll()
	}
	
	@objc
	func sessionRuntimeError(notification: NSNotification) {
		guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
		
		print("Capture session runtime error: \(error)")
		
		/*
         Try to restart the session running if media services were reset and the
         last start running succeeded. Otherwise, enable the user to try to
         resume the session running.
		*/
		if error.code == .mediaServicesWereReset {
			sessionQueue.async {
				if self.isSessionRunning {
					self.session.startRunning()
					self.isSessionRunning = self.session.isRunning
				}
			}
		}
 	}
	
	@objc
	func sessionWasInterrupted(notification: NSNotification) {
		/*
         In some scenarios, let the user resume the session. For example, when
         initializing music playback via control center, then the user allows
         AVCamBarcode to resume the session, which stops music playback. Note that
         stopping music playback in control center doesn't resume the session.
         Also note that it is not always possible to resume, see `resumeInterruptedSession(_:)`.
		*/
		if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
			let reasonIntegerValue = userInfoValue.integerValue,
			let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
			print("Capture session was interrupted with reason \(reason)")
			
			if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
				// Simply fade in a label to inform the user that the camera is unavailable.
				self.cameraUnavailableLabel.isHidden = false
				self.cameraUnavailableLabel.alpha = 0
				UIView.animate(withDuration: 0.25) {
					self.cameraUnavailableLabel.alpha = 1
				}
			}
		}
	}
	
	@objc
	func sessionInterruptionEnded(notification: NSNotification) {
		print("Capture session interruption ended")
		
		if cameraUnavailableLabel.isHidden {
			UIView.animate(withDuration: 0.25,
				animations: {
					self.cameraUnavailableLabel.alpha = 0
				}, completion: { _ in
					self.cameraUnavailableLabel.isHidden = true
				}
			)
		}
	}
	
	// MARK: Drawing Metadata Object Overlay Layers
    
    let candidates = ["aolig",
                      "baiossi",
                      "baiteman",
                      "cumhead",
                      "dao",
                      "dudu",
                      "eggman",
                      "faker",
                      "gaofei",
                      "giao",
                      "gothamnightmare",
                      "guizhouteethgirl",
                      "hanmeijuan",
                      "hanwang",
                      "hello",
                      "horsecawgenital",
                      "lao8",
                      "lili",
                      "lixueqin",
                      "poison",
                      "profguo",
                      "shamate",
                      "socialking",
                      "threedays",
                      "tianyiming",
                      "tigerbro",
                      "weiya",
                      "yingliu",
                      "zhongmm"].shuffled()
	
	private class MetadataObjectLayer: CAShapeLayer {
		var metadataObject: AVMetadataObject?
	}
	
	/*
     A dispatch semaphore the app uses for drawing metadata object overlays,
     so that the app draws only one group overlays at a time.
	*/
	private let metadataObjectsOverlayLayersDrawingSemaphore = DispatchSemaphore(value: 1)
	
	private var metadataObjectOverlayLayers = [MetadataObjectLayer]()
	
	private func createMetadataObjectOverlayWithMetadataObject(_ metadataObject: AVMetadataObject) -> MetadataObjectLayer {
		// Transform the metadata object so the bounds reflect those of the video preview layer.
		let transformedMetadataObject = previewView.videoPreviewLayer.transformedMetadataObject(for: metadataObject)
		
		// Create the initial metadata object overlay layer for either machine readable codes or faces.
		let metadataObjectOverlayLayer = MetadataObjectLayer()
		metadataObjectOverlayLayer.metadataObject = transformedMetadataObject
		
		if let faceMetadataObject = transformedMetadataObject as? AVMetadataFaceObject {
            let index = faceMetadataObject.faceID % candidates.count
            let iamgeName = candidates[index]
            let image = UIImage(named: iamgeName)

            let originalBounds = faceMetadataObject.bounds
            let newX = 1.5 * originalBounds.minX - 0.5 * originalBounds.midX
            let newY = 1.7 * originalBounds.minY - 0.7 * originalBounds.maxY
            let newWidth = 1.5 * originalBounds.width
            let newHeight = 2 * originalBounds.height
            let newBounds = CGRect(x: newX, y: newY, width: newWidth, height: newHeight)

            metadataObjectOverlayLayer.frame = newBounds
            metadataObjectOverlayLayer.bounds = newBounds
            metadataObjectOverlayLayer.contents = image?.cgImage
            
		}
		
		return metadataObjectOverlayLayer
	}
	
	private var removeMetadataObjectOverlayLayersTimer: Timer?
	
	@objc
	private func removeMetadataObjectOverlayLayers() {
		for sublayer in metadataObjectOverlayLayers {
			sublayer.removeFromSuperlayer()
		}
		metadataObjectOverlayLayers = []
		
		removeMetadataObjectOverlayLayersTimer?.invalidate()
		removeMetadataObjectOverlayLayersTimer = nil
	}
	
	private func addMetadataObjectOverlayLayersToVideoPreviewView(_ metadataObjectOverlayLayers: [MetadataObjectLayer]) {
		// Add the metadata object overlays as sublayers of the video preview layer.
        // Disable actions to allow for fast drawing.
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		for metadataObjectOverlayLayer in metadataObjectOverlayLayers {
			previewView.videoPreviewLayer.addSublayer(metadataObjectOverlayLayer)
		}
		CATransaction.commit()
		
		// Save the new metadata object overlays.
		self.metadataObjectOverlayLayers = metadataObjectOverlayLayers
		
		// Create a timer to destroy the metadata object overlays.
		removeMetadataObjectOverlayLayersTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(removeMetadataObjectOverlayLayers), userInfo: nil, repeats: false)
	}
	
	// MARK: AVCaptureMetadataOutputObjectsDelegate
	
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
		// Drop new notifications if old ones are still processing using `wait()`, to avoid queueing up stale data.
        if metadataObjectsOverlayLayersDrawingSemaphore.wait(timeout: .now()) == .success {
			DispatchQueue.main.async {
				self.removeMetadataObjectOverlayLayers()
				
				var metadataObjectOverlayLayers = [MetadataObjectLayer]()
				for metadataObject in metadataObjects {
					let metadataObjectOverlayLayer = self.createMetadataObjectOverlayWithMetadataObject(metadataObject)
					metadataObjectOverlayLayers.append(metadataObjectOverlayLayer)
				}
				
				self.addMetadataObjectOverlayLayersToVideoPreviewView(metadataObjectOverlayLayers)
				
				self.metadataObjectsOverlayLayersDrawingSemaphore.signal()
			}
		}
	}
}

extension AVCaptureVideoOrientation {
	init?(deviceOrientation: UIDeviceOrientation) {
		switch deviceOrientation {
		case .portrait: self = .portrait
		case .portraitUpsideDown: self = .portraitUpsideDown
		case .landscapeLeft: self = .landscapeRight
		case .landscapeRight: self = .landscapeLeft
		default: return nil
		}
	}
	
	init?(interfaceOrientation: UIInterfaceOrientation) {
		switch interfaceOrientation {
		case .portrait: self = .portrait
		case .portraitUpsideDown: self = .portraitUpsideDown
		case .landscapeLeft: self = .landscapeLeft
		case .landscapeRight: self = .landscapeRight
		default: return nil
		}
	}
}
