#if os(tvOS)
import AVFoundation
import AVKit
import CoreMedia
import UCRender
import UIKit

/// Asks tvOS to switch the TV to the mode that matches what the renderer outputs, at 4K 60 Hz.
///
/// Apps cannot author Dolby Vision for real-time rendering; on an HDR TV the renderer outputs
/// PQ BT.2100 (HDR10) and the criteria ask for the TV's Dolby Vision mode, into which tvOS maps
/// the HDR10 frames. On an SDR TV it asks for BT.709 SDR so nothing is converted. Switching only
/// happens when Settings › Video and Audio › Match Content (Dynamic Range / Frame Rate) is on.
enum DisplayMode {
    @MainActor
    static func request(for window: UIWindow, output: HDROutput.Mode) {
        let hdr = output == .pq
        let extensions: [CFString: Any] = hdr
            ? [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            ]
            : [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            ]
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: hdr ? kCMVideoCodecType_DolbyVisionHEVC : kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else { return }
        // Never crash over a display-mode hint: without AVKit loaded the category is missing.
        guard window.responds(to: #selector(getter: UIWindow.avDisplayManager)) else { return }
        window.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: 60, formatDescription: format)
    }
}
#endif
