#ifndef PTPEEP_CFFMPEG_SHIM_H
#define PTPEEP_CFFMPEG_SHIM_H

// Umbrella header bridging Swift → FFmpeg C libraries (libav*).
// Kept narrow: only the headers the video decoder / audio extractor call into.
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libavutil/error.h>
#include <libavutil/timestamp.h>
#include <libavutil/samplefmt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mathematics.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

#endif
