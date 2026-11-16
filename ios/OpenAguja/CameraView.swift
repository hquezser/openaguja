import AVFoundation
import SwiftUI

/// Écran caméra : aperçu plein écran + déclencheur. Tant qu'il est affiché
/// (premier plan — règle iOS), un appui sur « Appareil photo » de la montre
/// prend la photo et l'enregistre dans la photothèque.
struct CameraView: View {
    @ObservedObject var phone: PhoneActions

    var body: some View {
        ZStack {
            CameraPreview { layer in
                phone.armCamera(previewLayer: layer)
            }
            .ignoresSafeArea()
            if let shot = phone.lastShot {
                VStack {
                    Spacer()
                    HStack {
                        Image(uiImage: shot)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding()
                        Spacer()
                    }
                }
            }
            VStack {
                Spacer()
                Button {
                    phone.shoot()
                } label: {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 72, height: 72)
                        .overlay(Circle().fill(.white).padding(6))
                }
                .padding(.bottom, 32)
            }
        }
        .background(.black)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { phone.disarmCamera() }
    }
}

/// Aperçu AVCaptureVideoPreviewLayer ; la couche est passée à PhoneActions
/// qui y branche la session une fois armée.
private struct CameraPreview: UIViewRepresentable {
    let onLayer: (AVCaptureVideoPreviewLayer) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        onLayer(view.layer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        override var layer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            super.layer as! AVCaptureVideoPreviewLayer
        }
    }
}
