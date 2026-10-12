#if os(tvOS)
import AVKit
import CoreMedia
import UIKit

/// Asks tvOS to switch the TV to 4K / 60 Hz / Dolby Vision.
///
/// Apps cannot author Dolby Vision for real-time rendering; the renderer outputs PQ BT.2100
/// (HDR10). Requesting a Dolby Vision display criteria puts the TV in its Dolby Vision mode,
/// and tvOS maps the HDR10 frames into it. The switch only happens when the user enabled
/// Settings › Video and Audio › Match Content › Match Dynamic Range / Frame Rate.
enum DisplayMode {
    @MainActor
    static func request4KHDR60(for window: UIWindow) {
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ]
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_DolbyVisionHEVC,
            width: 3840,
            height: 2160,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else { return }
        window.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: 60, formatDescription: format)
    }
}
#endif
