import CFFmpeg
import Foundation

/// Minimal FFmpeg link/runtime probe. Confirms the CFFmpeg bridge is wired into the
/// app target and the libav dylibs actually load at runtime (hardened runtime +
/// Homebrew-signed dylibs). Logged once at launch; expand into the real decoder next.
/// See Docs/timecode-synced-video-playback-handoff.md.
enum FFmpegSupport {
    /// libavformat version + build string + whether the DNxHD decoder is available.
    static func versionInfo() -> String {
        let v = avformat_version()
        let build = String(cString: av_version_info())
        let hasDNx = avcodec_find_decoder_by_name("dnxhd") != nil
                  || avcodec_find_decoder_by_name("dnxhr") != nil
        return "libavformat \((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
             + " (build \(build)); dnx decoder: \(hasDNx ? "yes" : "NO")"
    }
}
