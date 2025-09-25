#ifndef __FPGA_ARCH_GEN_H__
#define __FPGA_ARCH_GEN_H__

// vectorization
#define K_VECTOR 4
#define C_VECTOR 4
#define NUM_LANES 1
#define NUM_INTERLEAVED_FEATURES 12
#define NUM_INTERLEAVED_FILTERS 1
#define INPUT_FEEDER_K_VECTOR 4
// precision
#define BLOCKFP_SELECT_RATIO 1
#define BLOCKFP_SB_WIDTH 7
#define BLOCKFP_INPUT_DOT_WIDTH 7
#define BLOCKFP_FEATURE_EXPONENT_WIDTH 5
#define BLOCKFP_FILTER_EXPONENT_WIDTH 5
#define AUX_DATA_VALUE_MANTISSA_WIDTH 10
// filter scratchpad
#define FILTER_CACHE_DEPTH 1532
#define BIAS_SCALE_CACHE_DEPTH 26
// feature scratchpad
#define STREAM_BUFFER_DEPTH 2048
#define SB_C_BANKS 4
#define SB_CVEC_BANK_PACK 2
// stride, dilation
#define MAX_WIDTH_STRIDE 15
#define MAX_HEIGHT_STRIDE 15
#define MAX_DILATION 16
// windowed aux. modules
#define POOL_SHIFT_P_MAX 2
#define POOL_SHIFT_Q_MAX 2
#define NORM_SHIFT_K 0
#define ENABLE_ELTWISE_MULT 
// max feature / filter dimensions
CONSTANT int output_channels_max = 8192;
CONSTANT int filter_size_width_max = 16;
CONSTANT int filter_size_height_max = 16;
CONSTANT int output_image_width_max = 128;
CONSTANT int output_image_height_max = 128;

#endif
