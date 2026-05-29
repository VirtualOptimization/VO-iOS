//
//  RoomCaptureViewController.swift
//  RoomPlanExporter
//
//  Created by Jung Hyun Han on 4/8/26.
//  Copyright © 2026 Apple. All rights reserved.
//

import UIKit
import RoomPlan
import SwiftUI

// MARK: - Delegate Protocol

protocol RoomCaptureViewControllerDelegate: AnyObject {
    func roomCaptureDidFinish(_ capturedRoom: CapturedRoom)
    func roomCaptureDidCancel()
}

// MARK: - RoomCaptureViewController

class RoomCaptureViewController: UIViewController {
    
    weak var delegate: RoomCaptureViewControllerDelegate?
    
    // RoomPlan 스캔 세션
    private var captureSession: RoomCaptureSession!
    
    // RoomPlan 스캔 뷰
    private var roomCaptureView: RoomCaptureView!
    
    // 스캔 완료 후 결과 처리하는 RoomBuilder
    private let roomBuilder = RoomBuilder(options: [.beautifyObjects])
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupRoomCaptureView()
        setupButtons()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }
    
    // MARK: - Setup
    
    private func setupRoomCaptureView() {
        // RoomCaptureView 생성 및 세션 연결
        let captureView = RoomCaptureView(frame: view.bounds)
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(captureView)
        roomCaptureView = captureView
        
        // 세션 delegate 연결
        captureSession = captureView.captureSession
        captureSession.delegate = self
    }
    
    private func setupButtons() {
        // 완료 버튼
        let doneButton = UIButton(type: .system)
        doneButton.setTitle("스캔 완료", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        doneButton.backgroundColor = .systemBlue
        doneButton.setTitleColor(.white, for: .normal)
        doneButton.layer.cornerRadius = 22
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        view.addSubview(doneButton)
        
        // 취소 버튼
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("취소", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancelButton)
        
        NSLayoutConstraint.activate([
            doneButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            doneButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            doneButton.widthAnchor.constraint(equalToConstant: 160),
            doneButton.heightAnchor.constraint(equalToConstant: 44),
            
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }
    
    // MARK: - Session Control
    
    private func startSession() {
        let config = RoomCaptureSession.Configuration()
        captureSession.run(configuration: config)
    }
    
    private func stopSession() {
        captureSession.stop()
    }
    
    // MARK: - Button Actions
    
    @objc private func doneTapped() {
        stopSession()
    }
    
    @objc private func cancelTapped() {
        stopSession()
        delegate?.roomCaptureDidCancel()
        dismiss(animated: true)
    }
}

// MARK: - RoomCaptureSessionDelegate

extension RoomCaptureViewController: RoomCaptureSessionDelegate {
    
    // 스캔 중 실시간 업데이트 (옵션 - 필요 시 활용)
    func captureSession(_ session: RoomCaptureSession,
                        didUpdate room: CapturedRoom,
                        error: (any Error)?) {
        if let error {
            print("스캔 업데이트 오류: \(error.localizedDescription)")
        }
    }
    
    // 스캔 완료 시 호출
    func captureSession(_ session: RoomCaptureSession,
                        didEndWith data: CapturedRoomData,
                        error: (any Error)?) {
        if let error {
            print("스캔 종료 오류: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.delegate?.roomCaptureDidCancel()
                self.dismiss(animated: true)
            }
            return
        }
        
        // RoomBuilder로 CapturedRoom 생성
        Task {
            do {
                let capturedRoom = try await roomBuilder.capturedRoom(from: data)
                await MainActor.run {
                    self.delegate?.roomCaptureDidFinish(capturedRoom)
                    self.dismiss(animated: true)
                }
            } catch {
                print("RoomBuilder 오류: \(error.localizedDescription)")
                await MainActor.run {
                    self.delegate?.roomCaptureDidCancel()
                    self.dismiss(animated: true)
                }
            }
        }
    }
}

// MARK: - SwiftUI 브릿지

/// SwiftUI에서 RoomCaptureViewController를 사용하기 위한 래퍼
struct RoomCaptureViewControllerRepresentable: UIViewControllerRepresentable {
    
    var onFinish: (CapturedRoom) -> Void
    var onCancel: () -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel)
    }
    
    func makeUIViewController(context: Context) -> RoomCaptureViewController {
        let vc = RoomCaptureViewController()
        vc.delegate = context.coordinator
        return vc
    }
    
    func updateUIViewController(_ uiViewController: RoomCaptureViewController, context: Context) {}
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, RoomCaptureViewControllerDelegate {
        var onFinish: (CapturedRoom) -> Void
        var onCancel: () -> Void
        
        init(onFinish: @escaping (CapturedRoom) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }
        
        func roomCaptureDidFinish(_ capturedRoom: CapturedRoom) {
            onFinish(capturedRoom)
        }
        
        func roomCaptureDidCancel() {
            onCancel()
        }
    }
}
