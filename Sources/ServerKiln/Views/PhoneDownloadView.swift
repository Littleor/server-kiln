import SwiftUI
import ServerKilnUI
import CoreImage.CIFilterBuiltins

struct PhoneDownloadView: View {
    static let websiteURL = URL(string: "https://serverkiln.littleor.cn")!
    static let downloadURL = URL(string: "https://apps.apple.com/app/id6830588008")!
    @Environment(\.dismiss) private var dismiss

    private var qrCode: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(Self.downloadURL.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("下载 iPhone 版", systemImage: "iphone")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel(Text("完成"))
                    .keyboardShortcut(.cancelAction)
            }
            VStack(spacing: 12) {
                if let qrCode {
                    Image(decorative: qrCode, scale: 1)
                        .interpolation(.none).resizable().scaledToFit()
                        .frame(width: 168, height: 168)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                        .accessibilityLabel("App Store 下载二维码")
                }
                Text("使用 iPhone 相机扫码，在 App Store 下载。")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .card()
            HStack(spacing: 8) {
                Link("访问官网", destination: Self.websiteURL)
                    .buttonStyle(IconButtonStyle())
                Spacer()
                Link("在 App Store 打开", destination: Self.downloadURL)
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(VisualEffectBackground().ignoresSafeArea())
    }
}
