import Foundation
import CFFmpeg

/// M0 link spike: proves the CFFmpeg module imports and the FFmpeg dylibs link.
/// (Will fold into LibavDecoder in M1; kept tiny for now.)
enum FFmpegProbe {
    static func versionString() -> String {
        let v = avformat_version()
        return "libavformat \((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
    }
}
