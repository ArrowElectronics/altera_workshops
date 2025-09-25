/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * 
* This code is supplied as-is.
* It is intended for demonstration use only.
*
* The code performs initializations of all modules involved.
* LED0 is illuminated Red to indicate sign of life when the runs
* LED0 changes to Green after all initalizations
* LED0 changes to Blue after receiving the 1st video frame.
*
*/
#define debug

#include "stdio.h"
#include "system.h"
#include "alt_types.h"
#include "io.h"
#include <sys/alt_sys_init.h>
#include "sys/alt_stdio.h"
#include "sys/alt_irq.h"
#include "altera_avalon_pio_regs.h"
#include "altera_avalon_i2c.h"
#include "altera_avalon_i2c_regs.h"
#include "altera_avalon_sysid_qsys.h"
#include "altera_avalon_sysid_qsys_regs.h"


//Camera I2C parameters
#define MIRA220_i2c_addr   0x54

#define MIRA220_RESETn                  0x00
#define MIRA220_ENABLE                  0x01
#define MIRA220_REG_CHIP_VER            0x001D	// 0x01D:[31:0], 0x01E[23:0], 0x025:[7:0]
#define MIRA220_REG_CHIP_REV            0x003A	// 0x03A[7:0]
#define MIRA220_REG_SW_RESET            0x0040
#define MIRA220_REG_EXPOSURE	        0x100C
#define MIRA220_REG_VBLANK              0x1012

#define MIRA220_TEST_PATTERN_CFG_REG	0x2091
#define MIRA220_TEST_PATTERN_ENABLE     1     // [0] = 1
#define MIRA220_TEST_PATTERN_VERT_GRAD  0x00  //[6:4] = 0x0
#define MIRA220_TEST_PATTERN_DIAG_GRAD  0x10  //[6:4] = 0x1
#define MIRA220_TEST_PATTERN_Walking_1  0x40  //[6:4] = 0x1
#define MIRA220_TEST_PATTERN_Walking_0  0x50  //[6:4] = 0x1

#define MIRA220_IMAGER_STATE_REG        0x1003
#define MIRA220_MASTER_EXPOSURE         0x10
#define MIRA220_STOP_AT_FRAME_BOUNDARY  0x04

#define MIRA220_IMAGER_RUN_CONT_REG		0x1002

#define MIRA220_IMAGER_RUN_REG			0x10F0
#define MIRA220_IMAGER_RUN_START		0x01
#define MIRA220_IMAGER_RUN_STOP			0x00

#define MIRA220_NB_OF_FRAMES_REG		0x10F2

#define MIRA220_MIPI_SOFT_RESET_REG 	0x5004
#define MIRA220_MIPI_SOFT_RESET_DPHY	0x01
#define MIRA220_MIPI_SOFT_RESET_NONE	0x00

#define MIRA220_MIPI_RST_CFG_REG		0x5011
#define MIRA220_MIPI_RST_CFG_ACTIVE 	0x00
#define MIRA220_MIPI_RST_CFG_SUSPEND 	0x01
#define MIRA220_MIPI_RST_CFG_STANDBY 	0x02

#define VVP_VFW_IMG_WIDTH           0x0120
#define VVP_VFW_IMG_HEIGHT          0x0124
#define VVP_VFW_COMMIT              0x0164
#define VVP_VFW_RUN                 0x016C
#define VVP_VFW_NUM_BUFFERS         0x0170
#define VVP_VFW_BUFFER_BASE         0x0174
#define VVP_VFW_INTER_BUFFER_OFFSET 0x0178
#define VVP_VFW_INTER_LINE_OFFSET   0x017C


#define WBC_IMG_WIDTH           0x0120
#define WBC_IMG_HEIGHT          0x0124
#define WBC_CFA_00_COLOR_SCALER 0x0150
#define WBC_CFA_01_COLOR_SCALER 0x0154
#define WBC_CFA_10_COLOR_SCALER 0x0158
#define WBC_CFA_11_COLOR_SCALER 0x015C
#define WBC_COMMIT              0x0148
#define WBC_CONTROL             0x014C

#define DEMOSAIC_IMG_WIDTH      0x0120
#define DEMOSAIC_IMG_HEIGHT     0x0124
#define DEMOSAIC_CONTROL        0x014C

#define VFW_IRQ_CONTROL         0x0100
#define VFW_IRQ_STATUS          0x0104
#define VFW_IMG_INFO_WIDTH      0x0120
#define VFW_IMG_INFO_HEIGHT     0x0124
#define VFW_STATUS              0x0140
#define VFW_BUFFER_AVAILABLE    0x0144
#define VFW_BUFFER_WRITE_COUNT  0x0148
#define VFW_BUFFER_START_ADDR   0x014C
#define VFW_COMMIT              0x0164
#define VFW_BUFFER_ACKNOWLEDGE  0x0168
#define VFW_RUN                 0x016C
#define VFW_NUM_BUFFERS         0x0170
#define VFW_BUFFER_BASE         0x0174
#define VFW_INTER_BUFFER_OFFSET 0x0178
#define VFW_INTER_LINE_OFFSET   0x017C


alt_8 poke(alt_u16 addr, alt_u8 val, alt_u8 len);
alt_8 peek(alt_u16 addr, alt_u8 len);
alt_u8 init_MIRA220 ();
void VFW_isr (void* context);
char HEX2ASCII (char HEX_IN);
void byte2bcd (char value);
void byte2bcd4 (alt_u16 value);
void word2ascii (alt_u16 value);
void long_word2ascii (alt_u32 value);
void PB_isr (void* context);
void signOn ();

alt_u8 wData[20];
alt_u8 rData[20];
alt_u32 tempo;
alt_u32 global_var;
unsigned char  uart_rx_char;

void dump_vfb ();
FILE *fptr;

struct mira220_reg {
	alt_u16 address;
	alt_u8 val;
};

alt_u8 exp_time_index;

// Camera exposure time setting for adjusting exposure due to exterior lighting
alt_u16 exp_time[] = {
		0x016C,	// 5ms
		0x02D8,	// 10ms
		0x0445,	// 15ms
		0x05B1,	// 20ms
		0x071D,	// 25ms
		0x0889,	// 30ms
		0x09F5,	// 35ms
		0x0B61,	// 40ms
		0x0CCE,	// 45ms
		0x0E3A,	// 50ms
		0x0FA6,	// 55ms
		0x10C9	// 59ms
};
// 1280x720_30fps_12b_2lanes
static const struct mira220_reg full_1500mbps_1280_720_30fps_12b_2lanes_reg[] = {
		// 30 fps
		{0x1003,0x2},  //Initial Upload
		{0x6006,0x0},  //Initial Upload
		{0x6012,0x1},  //Initial Upload
		{0x6013,0x0},  //Initial Upload
		{0x6006,0x1},  //Initial Upload
		{0x205D,0x0},  //Initial Upload
		{0x2063,0x0},  //Initial Upload
		{0x24DC,0x13},  //Initial Upload
		{0x24DD,0x3},  //Initial Upload
		{0x24DE,0x3},  //Initial Upload
		{0x24DF,0x0},  //Initial Upload
		{0x400A,0x8},  //Initial Upload
		{0x400B,0x0},  //Initial Upload
		{0x401A,0x8},  //Initial Upload
		{0x401B,0x0},  //Initial Upload
		{0x4006,0x8},  //Initial Upload
		{0x401C,0x6F},  //Initial Upload
		{0x204B,0x3},  //Initial Upload
		{0x205B,0x64},  //Initial Upload
		{0x205C,0x0},  //Initial Upload
		{0x4018,0x3F},  //Initial Upload
		{0x403B,0xB},  //Initial Upload
		{0x403E,0xE},  //Initial Upload
		{0x402B,0x6},  //Initial Upload
		{0x401E,0x2},  //Initial Upload
		{0x4038,0x3B},  //Initial Upload
		{0x1077,0x0},  //Initial Upload
		{0x1078,0x0},  //Initial Upload
		{0x1009,0x8},  //Initial Upload
		{0x100A,0x0},  //Initial Upload
		{0x110F,0x8},  //Initial Upload
		{0x1110,0x0},  //Initial Upload
		{0x1006,0x2},  //Initial Upload
		{0x402C,0x64},  //Initial Upload
		{0x3064,0x0},  //Initial Upload
		{0x3065,0xF0},  //Initial Upload
		{0x4013,0x13},  //Initial Upload
		{0x401F,0x9},  //Initial Upload
		{0x4020,0x13},  //Initial Upload
		{0x4044,0x75},  //Initial Upload
		{0x4027,0x0},  //Initial Upload
		{0x3215,0x69},  //Initial Upload
		{0x3216,0xF},  //Initial Upload
		{0x322B,0x69},  //Initial Upload
		{0x322C,0xF},  //Initial Upload
		{0x4051,0x80},  //Initial Upload
		{0x4052,0x10},  //Initial Upload
		{0x4057,0x80},  //Initial Upload
		{0x4058,0x10},  //Initial Upload
		{0x3212,0x59},  //Initial Upload
		{0x4047,0x8F},  //Initial Upload
		{0x4026,0x10},  //Initial Upload
		{0x4032,0x53},  //Initial Upload
		{0x4036,0x17},  //Initial Upload
		{0x50B8,0xF4},  //Initial Upload
		{0x3016,0x0},  //Initial Upload
		{0x3017,0x2C},  //Initial Upload
		{0x3018,0x8C},  //Initial Upload
		{0x3019,0x45},  //Initial Upload
		{0x301A,0x5},  //Initial Upload
		{0x3013,0xA},  //Initial Upload
		{0x301B,0x0},  //Initial Upload
		{0x301C,0x4},  //Initial Upload
		{0x301D,0x88},  //Initial Upload
		{0x301E,0x45},  //Initial Upload
		{0x301F,0x5},  //Initial Upload
		{0x3020,0x0},  //Initial Upload
		{0x3021,0x4},  //Initial Upload
		{0x3022,0x88},  //Initial Upload
		{0x3023,0x45},  //Initial Upload
		{0x3024,0x5},  //Initial Upload
		{0x3025,0x0},  //Initial Upload
		{0x3026,0x4},  //Initial Upload
		{0x3027,0x88},  //Initial Upload
		{0x3028,0x45},  //Initial Upload
		{0x3029,0x5},  //Initial Upload
		{0x302F,0x0},  //Initial Upload
		{0x3056,0x0},  //Initial Upload
		{0x3057,0x0},  //Initial Upload
		{0x3300,0x1},  //Initial Upload
		{0x3301,0x0},  //Initial Upload
		{0x3302,0xB0},  //Initial Upload
		{0x3303,0xB0},  //Initial Upload
		{0x3304,0x16},  //Initial Upload
		{0x3305,0x15},  //Initial Upload
		{0x3306,0x1},  //Initial Upload
		{0x3307,0x0},  //Initial Upload
		{0x3308,0x30},  //Initial Upload
		{0x3309,0xA0},  //Initial Upload
		{0x330A,0x16},  //Initial Upload
		{0x330B,0x15},  //Initial Upload
		{0x330C,0x1},  //Initial Upload
		{0x330D,0x0},  //Initial Upload
		{0x330E,0x30},  //Initial Upload
		{0x330F,0xA0},  //Initial Upload
		{0x3310,0x16},  //Initial Upload
		{0x3311,0x15},  //Initial Upload
		{0x3312,0x1},  //Initial Upload
		{0x3313,0x0},  //Initial Upload
		{0x3314,0x30},  //Initial Upload
		{0x3315,0xA0},  //Initial Upload
		{0x3316,0x16},  //Initial Upload
		{0x3317,0x15},  //Initial Upload
		{0x3318,0x1},  //Initial Upload
		{0x3319,0x0},  //Initial Upload
		{0x331A,0x30},  //Initial Upload
		{0x331B,0xA0},  //Initial Upload
		{0x331C,0x16},  //Initial Upload
		{0x331D,0x15},  //Initial Upload
		{0x331E,0x1},  //Initial Upload
		{0x331F,0x0},  //Initial Upload
		{0x3320,0x30},  //Initial Upload
		{0x3321,0xA0},  //Initial Upload
		{0x3322,0x16},  //Initial Upload
		{0x3323,0x15},  //Initial Upload
		{0x3324,0x1},  //Initial Upload
		{0x3325,0x0},  //Initial Upload
		{0x3326,0x30},  //Initial Upload
		{0x3327,0xA0},  //Initial Upload
		{0x3328,0x16},  //Initial Upload
		{0x3329,0x15},  //Initial Upload
		{0x332A,0x2B},  //Initial Upload
		{0x332B,0x0},  //Initial Upload
		{0x332C,0x30},  //Initial Upload
		{0x332D,0xA0},  //Initial Upload
		{0x332E,0x16},  //Initial Upload
		{0x332F,0x15},  //Initial Upload
		{0x3330,0x1},  //Initial Upload
		{0x3331,0x0},  //Initial Upload
		{0x3332,0x10},  //Initial Upload
		{0x3333,0xA0},  //Initial Upload
		{0x3334,0x16},  //Initial Upload
		{0x3335,0x15},  //Initial Upload
		{0x3058,0x8},  //Initial Upload
		{0x3059,0x0},  //Initial Upload
		{0x305A,0x9},  //Initial Upload
		{0x305B,0x0},  //Initial Upload
		{0x3336,0x1},  //Initial Upload
		{0x3337,0x0},  //Initial Upload
		{0x3338,0x90},  //Initial Upload
		{0x3339,0xB0},  //Initial Upload
		{0x333A,0x16},  //Initial Upload
		{0x333B,0x15},  //Initial Upload
		{0x333C,0x1F},  //Initial Upload
		{0x333D,0x0},  //Initial Upload
		{0x333E,0x10},  //Initial Upload
		{0x333F,0xA0},  //Initial Upload
		{0x3340,0x16},  //Initial Upload
		{0x3341,0x15},  //Initial Upload
		{0x3342,0x52},  //Initial Upload
		{0x3343,0x0},  //Initial Upload
		{0x3344,0x10},  //Initial Upload
		{0x3345,0x80},  //Initial Upload
		{0x3346,0x16},  //Initial Upload
		{0x3347,0x15},  //Initial Upload
		{0x3348,0x1},  //Initial Upload
		{0x3349,0x0},  //Initial Upload
		{0x334A,0x10},  //Initial Upload
		{0x334B,0x80},  //Initial Upload
		{0x334C,0x16},  //Initial Upload
		{0x334D,0x1D},  //Initial Upload
		{0x334E,0x1},  //Initial Upload
		{0x334F,0x0},  //Initial Upload
		{0x3350,0x50},  //Initial Upload
		{0x3351,0x84},  //Initial Upload
		{0x3352,0x16},  //Initial Upload
		{0x3353,0x1D},  //Initial Upload
		{0x3354,0x18},  //Initial Upload
		{0x3355,0x0},  //Initial Upload
		{0x3356,0x10},  //Initial Upload
		{0x3357,0x84},  //Initial Upload
		{0x3358,0x16},  //Initial Upload
		{0x3359,0x1D},  //Initial Upload
		{0x335A,0x80},  //Initial Upload
		{0x335B,0x2},  //Initial Upload
		{0x335C,0x10},  //Initial Upload
		{0x335D,0xC4},  //Initial Upload
		{0x335E,0x14},  //Initial Upload
		{0x335F,0x1D},  //Initial Upload
		{0x3360,0xA5},  //Initial Upload
		{0x3361,0x0},  //Initial Upload
		{0x3362,0x10},  //Initial Upload
		{0x3363,0x84},  //Initial Upload
		{0x3364,0x16},  //Initial Upload
		{0x3365,0x1D},  //Initial Upload
		{0x3366,0x1},  //Initial Upload
		{0x3367,0x0},  //Initial Upload
		{0x3368,0x90},  //Initial Upload
		{0x3369,0x84},  //Initial Upload
		{0x336A,0x16},  //Initial Upload
		{0x336B,0x1D},  //Initial Upload
		{0x336C,0x12},  //Initial Upload
		{0x336D,0x0},  //Initial Upload
		{0x336E,0x10},  //Initial Upload
		{0x336F,0x84},  //Initial Upload
		{0x3370,0x16},  //Initial Upload
		{0x3371,0x15},  //Initial Upload
		{0x3372,0x32},  //Initial Upload
		{0x3373,0x0},  //Initial Upload
		{0x3374,0x30},  //Initial Upload
		{0x3375,0x84},  //Initial Upload
		{0x3376,0x16},  //Initial Upload
		{0x3377,0x15},  //Initial Upload
		{0x3378,0x26},  //Initial Upload
		{0x3379,0x0},  //Initial Upload
		{0x337A,0x10},  //Initial Upload
		{0x337B,0x84},  //Initial Upload
		{0x337C,0x16},  //Initial Upload
		{0x337D,0x15},  //Initial Upload
		{0x337E,0x80},  //Initial Upload
		{0x337F,0x2},  //Initial Upload
		{0x3380,0x10},  //Initial Upload
		{0x3381,0xC4},  //Initial Upload
		{0x3382,0x14},  //Initial Upload
		{0x3383,0x15},  //Initial Upload
		{0x3384,0xA9},  //Initial Upload
		{0x3385,0x0},  //Initial Upload
		{0x3386,0x10},  //Initial Upload
		{0x3387,0x84},  //Initial Upload
		{0x3388,0x16},  //Initial Upload
		{0x3389,0x15},  //Initial Upload
		{0x338A,0x41},  //Initial Upload
		{0x338B,0x0},  //Initial Upload
		{0x338C,0x10},  //Initial Upload
		{0x338D,0x80},  //Initial Upload
		{0x338E,0x16},  //Initial Upload
		{0x338F,0x15},  //Initial Upload
		{0x3390,0x2},  //Initial Upload
		{0x3391,0x0},  //Initial Upload
		{0x3392,0x10},  //Initial Upload
		{0x3393,0xA0},  //Initial Upload
		{0x3394,0x16},  //Initial Upload
		{0x3395,0x15},  //Initial Upload
		{0x305C,0x18},  //Initial Upload
		{0x305D,0x0},  //Initial Upload
		{0x305E,0x19},  //Initial Upload
		{0x305F,0x0},  //Initial Upload
		{0x3396,0x1},  //Initial Upload
		{0x3397,0x0},  //Initial Upload
		{0x3398,0x90},  //Initial Upload
		{0x3399,0x30},  //Initial Upload
		{0x339A,0x56},  //Initial Upload
		{0x339B,0x57},  //Initial Upload
		{0x339C,0x1},  //Initial Upload
		{0x339D,0x0},  //Initial Upload
		{0x339E,0x10},  //Initial Upload
		{0x339F,0x20},  //Initial Upload
		{0x33A0,0xD6},  //Initial Upload
		{0x33A1,0x17},  //Initial Upload
		{0x33A2,0x1},  //Initial Upload
		{0x33A3,0x0},  //Initial Upload
		{0x33A4,0x10},  //Initial Upload
		{0x33A5,0x28},  //Initial Upload
		{0x33A6,0xD6},  //Initial Upload
		{0x33A7,0x17},  //Initial Upload
		{0x33A8,0x3},  //Initial Upload
		{0x33A9,0x0},  //Initial Upload
		{0x33AA,0x10},  //Initial Upload
		{0x33AB,0x20},  //Initial Upload
		{0x33AC,0xD6},  //Initial Upload
		{0x33AD,0x17},  //Initial Upload
		{0x33AE,0x61},  //Initial Upload
		{0x33AF,0x0},  //Initial Upload
		{0x33B0,0x10},  //Initial Upload
		{0x33B1,0x20},  //Initial Upload
		{0x33B2,0xD6},  //Initial Upload
		{0x33B3,0x15},  //Initial Upload
		{0x33B4,0x1},  //Initial Upload
		{0x33B5,0x0},  //Initial Upload
		{0x33B6,0x10},  //Initial Upload
		{0x33B7,0x20},  //Initial Upload
		{0x33B8,0xD6},  //Initial Upload
		{0x33B9,0x1D},  //Initial Upload
		{0x33BA,0x1},  //Initial Upload
		{0x33BB,0x0},  //Initial Upload
		{0x33BC,0x50},  //Initial Upload
		{0x33BD,0x20},  //Initial Upload
		{0x33BE,0xD6},  //Initial Upload
		{0x33BF,0x1D},  //Initial Upload
		{0x33C0,0x2C},  //Initial Upload
		{0x33C1,0x0},  //Initial Upload
		{0x33C2,0x10},  //Initial Upload
		{0x33C3,0x20},  //Initial Upload
		{0x33C4,0xD6},  //Initial Upload
		{0x33C5,0x1D},  //Initial Upload
		{0x33C6,0x1},  //Initial Upload
		{0x33C7,0x0},  //Initial Upload
		{0x33C8,0x90},  //Initial Upload
		{0x33C9,0x20},  //Initial Upload
		{0x33CA,0xD6},  //Initial Upload
		{0x33CB,0x1D},  //Initial Upload
		{0x33CC,0x83},  //Initial Upload
		{0x33CD,0x0},  //Initial Upload
		{0x33CE,0x10},  //Initial Upload
		{0x33CF,0x20},  //Initial Upload
		{0x33D0,0xD6},  //Initial Upload
		{0x33D1,0x15},  //Initial Upload
		{0x33D2,0x1},  //Initial Upload
		{0x33D3,0x0},  //Initial Upload
		{0x33D4,0x10},  //Initial Upload
		{0x33D5,0x30},  //Initial Upload
		{0x33D6,0xD6},  //Initial Upload
		{0x33D7,0x15},  //Initial Upload
		{0x33D8,0x1},  //Initial Upload
		{0x33D9,0x0},  //Initial Upload
		{0x33DA,0x10},  //Initial Upload
		{0x33DB,0x20},  //Initial Upload
		{0x33DC,0xD6},  //Initial Upload
		{0x33DD,0x15},  //Initial Upload
		{0x33DE,0x1},  //Initial Upload
		{0x33DF,0x0},  //Initial Upload
		{0x33E0,0x10},  //Initial Upload
		{0x33E1,0x20},  //Initial Upload
		{0x33E2,0x56},  //Initial Upload
		{0x33E3,0x15},  //Initial Upload
		{0x33E4,0x7},  //Initial Upload
		{0x33E5,0x0},  //Initial Upload
		{0x33E6,0x10},  //Initial Upload
		{0x33E7,0x20},  //Initial Upload
		{0x33E8,0x16},  //Initial Upload
		{0x33E9,0x15},  //Initial Upload
		{0x3060,0x26},  //Initial Upload
		{0x3061,0x0},  //Initial Upload
		{0x302A,0xFF},  //Initial Upload
		{0x302B,0xFF},  //Initial Upload
		{0x302C,0xFF},  //Initial Upload
		{0x302D,0xFF},  //Initial Upload
		{0x302E,0x3F},  //Initial Upload
		{0x3013,0xB},  //Initial Upload
		{0x102B,0x2C},  //Initial Upload
		{0x102C,0x1},  //Initial Upload
		{0x1035,0x54},  //Initial Upload
		{0x1036,0x0},  //Initial Upload
		{0x3090,0x2A},  //Initial Upload
		{0x3091,0x1},  //Initial Upload
		{0x30C6,0x5},  //Initial Upload
		{0x30C7,0x0},  //Initial Upload
		{0x30C8,0x0},  //Initial Upload
		{0x30C9,0x0},  //Initial Upload
		{0x30CA,0x0},  //Initial Upload
		{0x30CB,0x0},  //Initial Upload
		{0x30CC,0x0},  //Initial Upload
		{0x30CD,0x0},  //Initial Upload
		{0x30CE,0x0},  //Initial Upload
		{0x30CF,0x5},  //Initial Upload
		{0x30D0,0x0},  //Initial Upload
		{0x30D1,0x0},  //Initial Upload
		{0x30D2,0x0},  //Initial Upload
		{0x30D3,0x0},  //Initial Upload
		{0x30D4,0x0},  //Initial Upload
		{0x30D5,0x0},  //Initial Upload
		{0x30D6,0x0},  //Initial Upload
		{0x30D7,0x0},  //Initial Upload
		{0x30F3,0x5},  //Initial Upload
		{0x30F4,0x0},  //Initial Upload
		{0x30F5,0x0},  //Initial Upload
		{0x30F6,0x0},  //Initial Upload
		{0x30F7,0x0},  //Initial Upload
		{0x30F8,0x0},  //Initial Upload
		{0x30F9,0x0},  //Initial Upload
		{0x30FA,0x0},  //Initial Upload
		{0x30FB,0x0},  //Initial Upload
		{0x30D8,0x5},  //Initial Upload
		{0x30D9,0x0},  //Initial Upload
		{0x30DA,0x0},  //Initial Upload
		{0x30DB,0x0},  //Initial Upload
		{0x30DC,0x0},  //Initial Upload
		{0x30DD,0x0},  //Initial Upload
		{0x30DE,0x0},  //Initial Upload
		{0x30DF,0x0},  //Initial Upload
		{0x30E0,0x0},  //Initial Upload
		{0x30E1,0x5},  //Initial Upload
		{0x30E2,0x0},  //Initial Upload
		{0x30E3,0x0},  //Initial Upload
		{0x30E4,0x0},  //Initial Upload
		{0x30E5,0x0},  //Initial Upload
		{0x30E6,0x0},  //Initial Upload
		{0x30E7,0x0},  //Initial Upload
		{0x30E8,0x0},  //Initial Upload
		{0x30E9,0x0},  //Initial Upload
		{0x30F3,0x5},  //Initial Upload
		{0x30F4,0x2},  //Initial Upload
		{0x30F5,0x0},  //Initial Upload
		{0x30F6,0x17},  //Initial Upload
		{0x30F7,0x1},  //Initial Upload
		{0x30F8,0x0},  //Initial Upload
		{0x30F9,0x0},  //Initial Upload
		{0x30FA,0x0},  //Initial Upload
		{0x30FB,0x0},  //Initial Upload
		{0x30D8,0x3},  //Initial Upload
		{0x30D9,0x1},  //Initial Upload
		{0x30DA,0x0},  //Initial Upload
		{0x30DB,0x19},  //Initial Upload
		{0x30DC,0x1},  //Initial Upload
		{0x30DD,0x0},  //Initial Upload
		{0x30DE,0x0},  //Initial Upload
		{0x30DF,0x0},  //Initial Upload
		{0x30E0,0x0},  //Initial Upload
		{0x30A2,0x5},  //Initial Upload
		{0x30A3,0x2},  //Initial Upload
		{0x30A4,0x0},  //Initial Upload
		{0x30A5,0x22},  //Initial Upload
		{0x30A6,0x0},  //Initial Upload
		{0x30A7,0x0},  //Initial Upload
		{0x30A8,0x0},  //Initial Upload
		{0x30A9,0x0},  //Initial Upload
		{0x30AA,0x0},  //Initial Upload
		{0x30AB,0x5},  //Initial Upload
		{0x30AC,0x2},  //Initial Upload
		{0x30AD,0x0},  //Initial Upload
		{0x30AE,0x22},  //Initial Upload
		{0x30AF,0x0},  //Initial Upload
		{0x30B0,0x0},  //Initial Upload
		{0x30B1,0x0},  //Initial Upload
		{0x30B2,0x0},  //Initial Upload
		{0x30B3,0x0},  //Initial Upload
		{0x30BD,0x5},  //Initial Upload
		{0x30BE,0x9F},  //Initial Upload
		{0x30BF,0x0},  //Initial Upload
		{0x30C0,0x7D},  //Initial Upload
		{0x30C1,0x0},  //Initial Upload
		{0x30C2,0x0},  //Initial Upload
		{0x30C3,0x0},  //Initial Upload
		{0x30C4,0x0},  //Initial Upload
		{0x30C5,0x0},  //Initial Upload
		{0x30B4,0x4},  //Initial Upload
		{0x30B5,0x9C},  //Initial Upload
		{0x30B6,0x0},  //Initial Upload
		{0x30B7,0x7D},  //Initial Upload
		{0x30B8,0x0},  //Initial Upload
		{0x30B9,0x0},  //Initial Upload
		{0x30BA,0x0},  //Initial Upload
		{0x30BB,0x0},  //Initial Upload
		{0x30BC,0x0},  //Initial Upload
		{0x30FC,0x5},  //Initial Upload
		{0x30FD,0x0},  //Initial Upload
		{0x30FE,0x0},  //Initial Upload
		{0x30FF,0x0},  //Initial Upload
		{0x3100,0x0},  //Initial Upload
		{0x3101,0x0},  //Initial Upload
		{0x3102,0x0},  //Initial Upload
		{0x3103,0x0},  //Initial Upload
		{0x3104,0x0},  //Initial Upload
		{0x3105,0x5},  //Initial Upload
		{0x3106,0x0},  //Initial Upload
		{0x3107,0x0},  //Initial Upload
		{0x3108,0x0},  //Initial Upload
		{0x3109,0x0},  //Initial Upload
		{0x310A,0x0},  //Initial Upload
		{0x310B,0x0},  //Initial Upload
		{0x310C,0x0},  //Initial Upload
		{0x310D,0x0},  //Initial Upload
		{0x3099,0x5},  //Initial Upload
		{0x309A,0x96},  //Initial Upload
		{0x309B,0x0},  //Initial Upload
		{0x309C,0x6},  //Initial Upload
		{0x309D,0x0},  //Initial Upload
		{0x309E,0x0},  //Initial Upload
		{0x309F,0x0},  //Initial Upload
		{0x30A0,0x0},  //Initial Upload
		{0x30A1,0x0},  //Initial Upload
		{0x310E,0x5},  //Initial Upload
		{0x310F,0x2},  //Initial Upload
		{0x3110,0x0},  //Initial Upload
		{0x3111,0x2B},  //Initial Upload
		{0x3112,0x0},  //Initial Upload
		{0x3113,0x0},  //Initial Upload
		{0x3114,0x0},  //Initial Upload
		{0x3115,0x0},  //Initial Upload
		{0x3116,0x0},  //Initial Upload
		{0x3117,0x5},  //Initial Upload
		{0x3118,0x2},  //Initial Upload
		{0x3119,0x0},  //Initial Upload
		{0x311A,0x2C},  //Initial Upload
		{0x311B,0x0},  //Initial Upload
		{0x311C,0x0},  //Initial Upload
		{0x311D,0x0},  //Initial Upload
		{0x311E,0x0},  //Initial Upload
		{0x311F,0x0},  //Initial Upload
		{0x30EA,0x0},  //Initial Upload
		{0x30EB,0x0},  //Initial Upload
		{0x30EC,0x0},  //Initial Upload
		{0x30ED,0x0},  //Initial Upload
		{0x30EE,0x0},  //Initial Upload
		{0x30EF,0x0},  //Initial Upload
		{0x30F0,0x0},  //Initial Upload
		{0x30F1,0x0},  //Initial Upload
		{0x30F2,0x0},  //Initial Upload
		{0x313B,0x3},  //Initial Upload
		{0x313C,0x31},  //Initial Upload
		{0x313D,0x0},  //Initial Upload
		{0x313E,0x7},  //Initial Upload
		{0x313F,0x0},  //Initial Upload
		{0x3140,0x68},  //Initial Upload
		{0x3141,0x0},  //Initial Upload
		{0x3142,0x34},  //Initial Upload
		{0x3143,0x0},  //Initial Upload
		{0x31A0,0x3},  //Initial Upload
		{0x31A1,0x16},  //Initial Upload
		{0x31A2,0x0},  //Initial Upload
		{0x31A3,0x8},  //Initial Upload
		{0x31A4,0x0},  //Initial Upload
		{0x31A5,0x7E},  //Initial Upload
		{0x31A6,0x0},  //Initial Upload
		{0x31A7,0x8},  //Initial Upload
		{0x31A8,0x0},  //Initial Upload
		{0x31A9,0x3},  //Initial Upload
		{0x31AA,0x16},  //Initial Upload
		{0x31AB,0x0},  //Initial Upload
		{0x31AC,0x8},  //Initial Upload
		{0x31AD,0x0},  //Initial Upload
		{0x31AE,0x7E},  //Initial Upload
		{0x31AF,0x0},  //Initial Upload
		{0x31B0,0x8},  //Initial Upload
		{0x31B1,0x0},  //Initial Upload
		{0x31B2,0x3},  //Initial Upload
		{0x31B3,0x16},  //Initial Upload
		{0x31B4,0x0},  //Initial Upload
		{0x31B5,0x8},  //Initial Upload
		{0x31B6,0x0},  //Initial Upload
		{0x31B7,0x7E},  //Initial Upload
		{0x31B8,0x0},  //Initial Upload
		{0x31B9,0x8},  //Initial Upload
		{0x31BA,0x0},  //Initial Upload
		{0x3120,0x5},  //Initial Upload
		{0x3121,0x45},  //Initial Upload
		{0x3122,0x0},  //Initial Upload
		{0x3123,0x1D},  //Initial Upload
		{0x3124,0x0},  //Initial Upload
		{0x3125,0xA9},  //Initial Upload
		{0x3126,0x0},  //Initial Upload
		{0x3127,0x6D},  //Initial Upload
		{0x3128,0x0},  //Initial Upload
		{0x3129,0x5},  //Initial Upload
		{0x312A,0x15},  //Initial Upload
		{0x312B,0x0},  //Initial Upload
		{0x312C,0xA},  //Initial Upload
		{0x312D,0x0},  //Initial Upload
		{0x312E,0x45},  //Initial Upload
		{0x312F,0x0},  //Initial Upload
		{0x3130,0x1D},  //Initial Upload
		{0x3131,0x0},  //Initial Upload
		{0x3132,0x5},  //Initial Upload
		{0x3133,0x7D},  //Initial Upload
		{0x3134,0x0},  //Initial Upload
		{0x3135,0xA},  //Initial Upload
		{0x3136,0x0},  //Initial Upload
		{0x3137,0xA9},  //Initial Upload
		{0x3138,0x0},  //Initial Upload
		{0x3139,0x6D},  //Initial Upload
		{0x313A,0x0},  //Initial Upload
		{0x3144,0x5},  //Initial Upload
		{0x3145,0x0},  //Initial Upload
		{0x3146,0x0},  //Initial Upload
		{0x3147,0x30},  //Initial Upload
		{0x3148,0x0},  //Initial Upload
		{0x3149,0x0},  //Initial Upload
		{0x314A,0x0},  //Initial Upload
		{0x314B,0x0},  //Initial Upload
		{0x314C,0x0},  //Initial Upload
		{0x314D,0x3},  //Initial Upload
		{0x314E,0x0},  //Initial Upload
		{0x314F,0x0},  //Initial Upload
		{0x3150,0x31},  //Initial Upload
		{0x3151,0x0},  //Initial Upload
		{0x3152,0x0},  //Initial Upload
		{0x3153,0x0},  //Initial Upload
		{0x3154,0x0},  //Initial Upload
		{0x3155,0x0},  //Initial Upload
		{0x31D8,0x5},  //Initial Upload
		{0x31D9,0x3A},  //Initial Upload
		{0x31DA,0x0},  //Initial Upload
		{0x31DB,0x2E},  //Initial Upload
		{0x31DC,0x0},  //Initial Upload
		{0x31DD,0x9E},  //Initial Upload
		{0x31DE,0x0},  //Initial Upload
		{0x31DF,0x7E},  //Initial Upload
		{0x31E0,0x0},  //Initial Upload
		{0x31E1,0x5},  //Initial Upload
		{0x31E2,0x4},  //Initial Upload
		{0x31E3,0x0},  //Initial Upload
		{0x31E4,0x4},  //Initial Upload
		{0x31E5,0x0},  //Initial Upload
		{0x31E6,0x73},  //Initial Upload
		{0x31E7,0x0},  //Initial Upload
		{0x31E8,0x4},  //Initial Upload
		{0x31E9,0x0},  //Initial Upload
		{0x31EA,0x5},  //Initial Upload
		{0x31EB,0x0},  //Initial Upload
		{0x31EC,0x0},  //Initial Upload
		{0x31ED,0x0},  //Initial Upload
		{0x31EE,0x0},  //Initial Upload
		{0x31EF,0x0},  //Initial Upload
		{0x31F0,0x0},  //Initial Upload
		{0x31F1,0x0},  //Initial Upload
		{0x31F2,0x0},  //Initial Upload
		{0x31F3,0x0},  //Initial Upload
		{0x31F4,0x0},  //Initial Upload
		{0x31F5,0x0},  //Initial Upload
		{0x31F6,0x0},  //Initial Upload
		{0x31F7,0x0},  //Initial Upload
		{0x31F8,0x0},  //Initial Upload
		{0x31F9,0x0},  //Initial Upload
		{0x31FA,0x0},  //Initial Upload
		{0x31FB,0x5},  //Initial Upload
		{0x31FC,0x0},  //Initial Upload
		{0x31FD,0x0},  //Initial Upload
		{0x31FE,0x0},  //Initial Upload
		{0x31FF,0x0},  //Initial Upload
		{0x3200,0x0},  //Initial Upload
		{0x3201,0x0},  //Initial Upload
		{0x3202,0x0},  //Initial Upload
		{0x3203,0x0},  //Initial Upload
		{0x3204,0x0},  //Initial Upload
		{0x3205,0x0},  //Initial Upload
		{0x3206,0x0},  //Initial Upload
		{0x3207,0x0},  //Initial Upload
		{0x3208,0x0},  //Initial Upload
		{0x3209,0x0},  //Initial Upload
		{0x320A,0x0},  //Initial Upload
		{0x320B,0x0},  //Initial Upload
		{0x3164,0x5},  //Initial Upload
		{0x3165,0x14},  //Initial Upload
		{0x3166,0x0},  //Initial Upload
		{0x3167,0xC},  //Initial Upload
		{0x3168,0x0},  //Initial Upload
		{0x3169,0x44},  //Initial Upload
		{0x316A,0x0},  //Initial Upload
		{0x316B,0x1F},  //Initial Upload
		{0x316C,0x0},  //Initial Upload
		{0x316D,0x5},  //Initial Upload
		{0x316E,0x7C},  //Initial Upload
		{0x316F,0x0},  //Initial Upload
		{0x3170,0xC},  //Initial Upload
		{0x3171,0x0},  //Initial Upload
		{0x3172,0xA8},  //Initial Upload
		{0x3173,0x0},  //Initial Upload
		{0x3174,0x6F},  //Initial Upload
		{0x3175,0x0},  //Initial Upload
		{0x31C4,0x5},  //Initial Upload
		{0x31C5,0x24},  //Initial Upload
		{0x31C6,0x1},  //Initial Upload
		{0x31C7,0x4},  //Initial Upload
		{0x31C8,0x0},  //Initial Upload
		{0x31C9,0x5},  //Initial Upload
		{0x31CA,0x24},  //Initial Upload
		{0x31CB,0x1},  //Initial Upload
		{0x31CC,0x4},  //Initial Upload
		{0x31CD,0x0},  //Initial Upload
		{0x31CE,0x5},  //Initial Upload
		{0x31CF,0x24},  //Initial Upload
		{0x31D0,0x1},  //Initial Upload
		{0x31D1,0x4},  //Initial Upload
		{0x31D2,0x0},  //Initial Upload
		{0x31D3,0x5},  //Initial Upload
		{0x31D4,0x73},  //Initial Upload
		{0x31D5,0x0},  //Initial Upload
		{0x31D6,0xB1},  //Initial Upload
		{0x31D7,0x0},  //Initial Upload
		{0x3176,0x5},  //Initial Upload
		{0x3177,0x10},  //Initial Upload
		{0x3178,0x0},  //Initial Upload
		{0x3179,0x56},  //Initial Upload
		{0x317A,0x0},  //Initial Upload
		{0x317B,0x0},  //Initial Upload
		{0x317C,0x0},  //Initial Upload
		{0x317D,0x0},  //Initial Upload
		{0x317E,0x0},  //Initial Upload
		{0x317F,0x5},  //Initial Upload
		{0x3180,0x6A},  //Initial Upload
		{0x3181,0x0},  //Initial Upload
		{0x3182,0xAD},  //Initial Upload
		{0x3183,0x0},  //Initial Upload
		{0x3184,0x0},  //Initial Upload
		{0x3185,0x0},  //Initial Upload
		{0x3186,0x0},  //Initial Upload
		{0x3187,0x0},  //Initial Upload
		{0x100C,0x7E},  //Initial Upload
		{0x100D,0x0},  //Initial Upload
		{0x1115,0x7E},  //Initial Upload
		{0x1116,0x0},  //Initial Upload
		{0x1012,0xDF},  //Initial Upload
		{0x1013,0x2B},  //Initial Upload
		{0x1002,0x4},  //Initial Upload
		{0x0043,0x0},  //Sensor Control Mode.SLEEP_POWER_MODE(0)
		{0x0043,0x0},  //Sensor Control Mode.IDLE_POWER_MODE(0)
		{0x0043,0x4},  //Sensor Control Mode.SYSTEM_CLOCK_ENABLE(0)
		{0x0043,0xC},  //Sensor Control Mode.SRAM_CLOCK_ENABLE(0)
		{0x1002,0x4},  //Sensor Control Mode.IMAGER_RUN_CONT(0)
		{0x1001,0x41},  //Sensor Control Mode.EXT_EVENT_SEL(0)
		{0x10F2,0x1},  //Sensor Control Mode.NB_OF_FRAMES_A(0)
		{0x10F3,0x0},  //Sensor Control Mode.NB_OF_FRAMES_A(1)
		{0x1111,0x1},  //Sensor Control Mode.NB_OF_FRAMES_B(0)
		{0x1112,0x0},  //Sensor Control Mode.NB_OF_FRAMES_B(1)
		{0x0012,0x0},  //IO Drive Strength.DIG_DRIVE_STRENGTH(0)
		{0x0012,0x0},  //IO Drive Strength.CCI_DRIVE_STRENGTH(0)
		{0x1001,0x41},  //Readout && Exposure.EXT_EXP_PW_SEL(0)
		{0x10D0,0x0},  //Readout && Exposure.EXT_EXP_PW_DELAY(0)
		{0x10D1,0x0},  //Readout && Exposure.EXT_EXP_PW_DELAY(1)
		{0x1012,0xB0},  //Readout && Exposure.VBLANK_A(0)
		{0x1013,0x9},  //Readout && Exposure.VBLANK_A(1)
		{0x1103,0x91},  //Readout && Exposure.VBLANK_B(0)
		{0x1104,0xD},  //Readout && Exposure.VBLANK_B(1)
		{0x100C,0x80},  //Readout && Exposure.EXP_TIME_A(0)
		{0x100D,0x0},  //Readout && Exposure.EXP_TIME_A(1)
		{0x1115,0x80},  //Readout && Exposure.EXP_TIME_B(0)
		{0x1116,0x0},  //Readout && Exposure.EXP_TIME_B(1)
		{0x102B,0x90},  //Readout && Exposure.ROW_LENGTH_A(0)
		{0x102C,0x1},  //Readout && Exposure.ROW_LENGTH_A(1)
		{0x1113,0x30},  //Readout && Exposure.ROW_LENGTH_B(0)
		{0x1114,0x1},  //Readout && Exposure.ROW_LENGTH_B(1)
		{0x2008,0x80},  //Horizontal ROI.HSIZE_A(0)
		{0x2009,0x2},  //Horizontal ROI.HSIZE_A(1)
		{0x2098,0x20},  //Horizontal ROI.HSIZE_B(0)
		{0x2099,0x3},  //Horizontal ROI.HSIZE_B(1)
		{0x200A,0x50},  //Horizontal ROI.HSTART_A(0)
		{0x200B,0x0},  //Horizontal ROI.HSTART_A(1)
		{0x209A,0x0},  //Horizontal ROI.HSTART_B(0)
		{0x209B,0x0},  //Horizontal ROI.HSTART_B(1)
		{0x207D,0x0},  //Horizontal ROI.MIPI_HSIZE(0)
		{0x207E,0x5},  //Horizontal ROI.MIPI_HSIZE(1)
		{0x107D,0x54},  //Vertical ROI.VSTART0_A(0)
		{0x107E,0x1},  //Vertical ROI.VSTART0_A(1)
		{0x1087,0xD0},  //Vertical ROI.VSIZE0_A(0)
		{0x1088,0x2},  //Vertical ROI.VSIZE0_A(1)
		{0x1105,0x0},  //Vertical ROI.VSTART0_B(0)
		{0x1106,0x0},  //Vertical ROI.VSTART0_B(1)
		{0x110A,0x78},  //Vertical ROI.VSIZE0_B(0)
		{0x110B,0x5},  //Vertical ROI.VSIZE0_B(1)
		{0x107D,0x54},  //Vertical ROI.VSTART1_A(0)
		{0x107E,0x1},  //Vertical ROI.VSTART1_A(1)
		{0x107F,0x0},  //Vertical ROI.VSTART1_A(2)
		{0x1087,0xD0},  //Vertical ROI.VSIZE1_A(0)
		{0x1088,0x2},  //Vertical ROI.VSIZE1_A(1)
		{0x1089,0x0},  //Vertical ROI.VSIZE1_A(2)
		{0x1105,0x0},  //Vertical ROI.VSTART1_B(0)
		{0x1106,0x0},  //Vertical ROI.VSTART1_B(1)
		{0x1107,0x0},  //Vertical ROI.VSTART1_B(2)
		{0x110A,0x78},  //Vertical ROI.VSIZE1_B(0)
		{0x110B,0x5},  //Vertical ROI.VSIZE1_B(1)
		{0x110C,0x0},  //Vertical ROI.VSIZE1_B(2)
		{0x107D,0x54},  //Vertical ROI.VSTART2_A(0)
		{0x107E,0x1},  //Vertical ROI.VSTART2_A(1)
		{0x107F,0x0},  //Vertical ROI.VSTART2_A(2)
		{0x1080,0x0},  //Vertical ROI.VSTART2_A(3)
		{0x1081,0x0},  //Vertical ROI.VSTART2_A(4)
		{0x1087,0xD0},  //Vertical ROI.VSIZE2_A(0)
		{0x1088,0x2},  //Vertical ROI.VSIZE2_A(1)
		{0x1089,0x0},  //Vertical ROI.VSIZE2_A(2)
		{0x108A,0x0},  //Vertical ROI.VSIZE2_A(3)
		{0x108B,0x0},  //Vertical ROI.VSIZE2_A(4)
		{0x1105,0x0},  //Vertical ROI.VSTART2_B(0)
		{0x1106,0x0},  //Vertical ROI.VSTART2_B(1)
		{0x1107,0x0},  //Vertical ROI.VSTART2_B(2)
		{0x1108,0x0},  //Vertical ROI.VSTART2_B(3)
		{0x1109,0x0},  //Vertical ROI.VSTART2_B(4)
		{0x110A,0x78},  //Vertical ROI.VSIZE2_B(0)
		{0x110B,0x5},  //Vertical ROI.VSIZE2_B(1)
		{0x110C,0x0},  //Vertical ROI.VSIZE2_B(2)
		{0x110D,0x0},  //Vertical ROI.VSIZE2_B(3)
		{0x110E,0x0},  //Vertical ROI.VSIZE2_B(4)
		{0x209C,0x0},  //Mirroring && Flipping.HFLIP_A(0)
		{0x209D,0x0},  //Mirroring && Flipping.HFLIP_B(0)
		{0x1095,0x0},  //Mirroring && Flipping.VFLIP(0)
		{0x2063,0x0},  //Mirroring && Flipping.BIT_ORDER(0)
		{0x6006,0x0},  //MIPI.TX_CTRL_EN(0)
		{0x5004,0x1},  //MIPI.datarate
		{0x5086,0x2},  //MIPI.datarate
		{0x5087,0x4E},  //MIPI.datarate
		{0x5088,0x0},  //MIPI.datarate
		{0x5090,0x0},  //MIPI.datarate
		{0x5091,0x8},  //MIPI.datarate
		{0x5092,0x14},  //MIPI.datarate
		{0x5093,0xF},  //MIPI.datarate
		{0x5094,0x6},  //MIPI.datarate
		{0x5095,0x32},  //MIPI.datarate
		{0x5096,0xE},  //MIPI.datarate
		{0x5097,0x0},  //MIPI.datarate
		{0x5098,0x11},  //MIPI.datarate
		{0x5004,0x0},  //MIPI.datarate
		{0x2066,0x6C},  //MIPI.datarate
		{0x2067,0x7},  //MIPI.datarate
		{0x206E,0x7E},  //MIPI.datarate
		{0x206F,0x6},  //MIPI.datarate
		{0x20AC,0x7E},  //MIPI.datarate
		{0x20AD,0x6},  //MIPI.datarate
		{0x2076,0xC8},  //MIPI.datarate
		{0x2077,0x0},  //MIPI.datarate
		{0x20B4,0xC8},  //MIPI.datarate
		{0x20B5,0x0},  //MIPI.datarate
		{0x2078,0x1E},  //MIPI.datarate
		{0x2079,0x4},  //MIPI.datarate
		{0x20B6,0x1E},  //MIPI.datarate
		{0x20B7,0x4},  //MIPI.datarate
		{0x207A,0xD4},  //MIPI.datarate
		{0x207B,0x4},  //MIPI.datarate
		{0x20B8,0xD4},  //MIPI.datarate
		{0x20B9,0x4},  //MIPI.datarate
		{0x208D,0x4},  //MIPI.CSI2_DTYPE(0)
		{0x208E,0x0},  //MIPI.CSI2_DTYPE(1)
		{0x207C,0x0},  //MIPI.VC_ID(0)
		{0x6001,0x7},  //MIPI.TINIT(0)
		{0x6002,0xD8},  //MIPI.TINIT(1)
		{0x6010,0x0},  //MIPI.FRAME_MODE(0)
		{0x6010,0x0},  //MIPI.EMBEDDED_FRAME_MODE(0)
		{0x6011,0x0},  //MIPI.DATA_ENABLE_POLARITY(0)
		{0x6011,0x0},  //MIPI.HSYNC_POLARITY(0)
		{0x6011,0x0},  //MIPI.VSYNC_POLARITY(0)
		{0x6012,0x1},  //MIPI.LANE(0)
		{0x6013,0x0},  //MIPI.CLK_MODE(0)
		{0x6016,0x0},  //MIPI.FRAME_COUNTER(0)
		{0x6017,0x0},  //MIPI.FRAME_COUNTER(1)
		{0x6037,0x0},  //MIPI.LINE_COUNT_RAW8(0)
		{0x6037,0x0},  //MIPI.LINE_COUNT_RAW10(0)
		{0x6037,0x4},  //MIPI.LINE_COUNT_RAW12(0)
		{0x6039,0x1},  //MIPI.LINE_COUNT_EMB(0)
		{0x6018,0x0},  //MIPI.CCI_READ_INTERRUPT_EN(0)
		{0x6018,0x0},  //MIPI.CCI_WRITE_INTERRUPT_EN(0)
		{0x6065,0x0},  //MIPI.TWAKE_TIMER(0)
		{0x6066,0x0},  //MIPI.TWAKE_TIMER(1)
		{0x601C,0x0},  //MIPI.SKEW_CAL_EN(0)
		{0x601D,0x0},  //MIPI.SKEW_COUNT(0)
		{0x601E,0x22},  //MIPI.SKEW_COUNT(1)
		{0x601F,0x0},  //MIPI.SCRAMBLING_EN(0)
		{0x6003,0x1},  //MIPI.INIT_SKEW_EN(0)
		{0x6004,0x7A},  //MIPI.INIT_SKEW(0)
		{0x6005,0x12},  //MIPI.INIT_SKEW(1)
		{0x6006,0x1},  //MIPI.TX_CTRL_EN(0)
		{0x4006,0x8},  //Processing.BSP(0)
		{0x209E,0x2},  //Processing.BIT_DEPTH(0)
		{0x2045,0x1},  //Processing.CDS_RNC(0)
		{0x2048,0x1},  //Processing.CDS_IMG(0)
		{0x204B,0x3},  //Processing.RNC_EN(0)
		{0x205B,0x64},  //Processing.RNC_DARK_TARGET(0)
		{0x205C,0x0},  //Processing.RNC_DARK_TARGET(1)
		{0x24DC,0x12},  //Defect Pixel Correction.DC_ENABLE(0)
		{0x24DC,0x10},  //Defect Pixel Correction.DC_MODE(0)
		{0x24DC,0x0},  //Defect Pixel Correction.DC_REPLACEMENT_VALUE(0)
		{0x24DD,0x0},  //Defect Pixel Correction.DC_LIMIT_LOW(0)
		{0x24DE,0x0},  //Defect Pixel Correction.DC_LIMIT_HIGH(0)
		{0x24DF,0x0},  //Defect Pixel Correction.DC_LIMIT_HIGH_MODE(0)
		{0x10D7,0x1},  //Illumination Trigger.ILLUM_EN(0)
		{0x10D8,0x2},  //Illumination Trigger.ILLUM_POL(0)
		{0x205D,0x0},  //Histogram.HIST_EN(0)
		{0x205E,0x0},  //Histogram.HIST_USAGE_RATIO(0)
		{0x2063,0x0},  //Histogram.PIXEL_DATA_SUPP(0)
		{0x2063,0x0},  //Histogram.PIXEL_TRANSMISSION(0)
		{0x2091,0x0},  //Test Pattern Generator.TPG_EN(0)
		{0x2091,0x0},  //Test Pattern Generator.TPG_CONFIG(0)
		//{0x1003,0x10},  //Software Trigger.IMAGER_STATE(0)
		//{0x10F0,0x1},  //Software Trigger.IMAGER_RUN(0)

};


ALT_AVALON_I2C_DEV_t *camera_i2c_dev, *power_i2c_dev;
ALT_AVALON_I2C_STATUS_CODE camera_i2c_status, power_i2c_status;

int main()
{

    // Initialize all of the HAL drivers used in this design (UART, SPI, onchip flash, etc.)
    alt_sys_init();
    //alt_irq_disable_all();

    alt_putstr("\r\n++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\r\n");
	alt_putstr("Revision : Mira220\r\n\n");

    // Camera Disabled
    IOWR_ALTERA_AVALON_PIO_DATA(NIOSV_SYSTEM_0_PIO_MIPI_BASE, MIRA220_RESETn);

	// activate sign of life in FPGA
    IOWR_ALTERA_AVALON_PIO_DATA(NIOSV_SYSTEM_0_PIO_LED_BASE, 0x03);  // Only Red LED on
    usleep(500000);

    // enable I2C ports
    camera_i2c_dev = alt_avalon_i2c_open(NIOSV_SYSTEM_0_CAMERA_I2C_NAME);
    if (NULL==camera_i2c_dev)    {
    	alt_putstr("Error: Cannot find MIPI I2C Peripheral\r\n");
    }

    //set the address of the MIPI I2C slave device
    alt_avalon_i2c_master_target_set(camera_i2c_dev,MIRA220_i2c_addr);

	// Print the System ID selected in hardware
    tempo = IORD_ALTERA_AVALON_SYSID_QSYS_ID(NIOSV_SYSTEM_0_SYSID_BASE);
    alt_putstr("System ID: 0x");
    long_word2ascii(tempo);
    alt_putstr("\r\n\n");

    // start at mid exposure
    exp_time_index = 6;

	// Enable PB IRQ in the Interrupt Controller
	alt_ic_irq_enable (NIOSV_SYSTEM_0_PIO_PB_IRQ_INTERRUPT_CONTROLLER_ID, NIOSV_SYSTEM_0_PIO_PB_IRQ);
    // Register the PB interrupt handler
	alt_ic_isr_register (NIOSV_SYSTEM_0_PIO_PB_IRQ_INTERRUPT_CONTROLLER_ID, NIOSV_SYSTEM_0_PIO_PB_IRQ, PB_isr, NULL, NULL);
    // Unmask the PB IRQ for USER_PB pin
    IOWR_ALTERA_AVALON_PIO_IRQ_MASK(NIOSV_SYSTEM_0_PIO_PB_BASE, 0x01);


	// Initialize the camera and Video IP suite components
	init_MIRA220 ();

    // activate sign of life in FPGA
    IOWR_ALTERA_AVALON_PIO_DATA(NIOSV_SYSTEM_0_PIO_LED_BASE, 0x05);  // Only Green LED on

    alt_putstr("\r\nDone Initializing\r\n");

    signOn();

    // Dummy infinite loop
    while (1) {
    // Read ASCII character from UART
    uart_rx_char = alt_getchar();
    if (uart_rx_char != 'v') {
    	alt_putchar(uart_rx_char);
    }

    // If key pressed is T/t, the accelerometer x/y/z axes are read and values displayed
    switch (uart_rx_char) {
    case 'D' : // dump 256-byte data block from VFB
    case 'd' :
    	for (alt_u8 j=0; j<128; j=j+4) {
            alt_putstr("\r\n");
    		global_var = IORD_32DIRECT (MIPI_SYSTEM_0_VID_FRAME_BUF_BASE,j);
        	long_word2ascii(global_var);
    	}
        break;
    case 'R' : // Read 16-bit data from VFB
    case 'r' :
        alt_putstr("\r\n");
    	global_var = IORD_32DIRECT (MIPI_SYSTEM_0_VID_FRAME_BUF_BASE,0);
    	long_word2ascii(global_var);
        break;
    case 'F' : // Fill HyperRAM
    case 'f' :
		global_var = 0xBEAD4507;
    	for (alt_u8 m=0; m<128; m=m+4) {
            alt_putstr("\r\n");
    		IOWR_32DIRECT (MIPI_SYSTEM_0_VID_FRAME_BUF_BASE,m, global_var);
    		alt_putstr("Wrote VFB address ");
    		byte2bcd(m);
    		alt_putstr(" with Data 0x");
    		long_word2ascii(global_var);
    		global_var = global_var + 0x12344321;
    	}
        break;
    case 'W' : // Write 1 word to VFB
    case 'w' :
		IOWR_32DIRECT (MIPI_SYSTEM_0_VID_FRAME_BUF_BASE,0, 0xDEADBEEF);
		alt_putstr("\r\nWrote hyperRAM address 0 with 0xDEADBEEF");
        break;
    case 'V' : // Dump Video Frame Buffer from HyperRAM
    case 'v' :
    	dump_vfb();
        break;
    default :
		signOn();
		break;
    }
    alt_putstr("\r\n>");
 }

}

/******************************************************************/


void signOn ()
{
	alt_putstr("\r\n");
	alt_putstr("Available Commands :\r\n");
	alt_putstr("F/f - Fill 32-bit words in HyperRAM\r\n");
	alt_putstr("V/v - Dump VFB (256 words)\r\n");
	alt_putstr("W/w - Write 32-bit word to HyperRAM Address 0\r\n");
	alt_putstr("R/r - Read 32-bit word from HyperRAM Address 0\r\n");
	alt_putstr(">");
}



/****************************************************************************/
// poke : Write 1 Byte to MIPI I2C
//   addr : 16-bit Register Address
//   val  : 8-bit Data Value
//   len  : =1 for 1-byte.
/****************************************************************************/
alt_8 poke(alt_u16 addr, alt_u8 val, alt_u8 len) {

	wData[0] = (alt_u8)(addr >> 8);
	wData[1] = (alt_u8)(addr & 0x0FF);
    wData[2] = val & 0xFF;

    camera_i2c_status = alt_avalon_i2c_master_tx(camera_i2c_dev,wData, 3, ALT_AVALON_I2C_NO_INTERRUPTS);
    if (camera_i2c_status != ALT_AVALON_I2C_SUCCESS) {
    	//printf("Error Writing to MIRA220 Address 0x%02X%02X\r\n", wData[0], wData[1]);
    	alt_putstr("Error Writing to MIRA220\r\n");
    	return 1;
    }
    return 0;
}

/****************************************************************************/
// peek : Reads Data from MIPI I2C. Data placed in rData[]
//   addr : 16-bit Register Address
//   len  : # of bytes to read
/****************************************************************************/
alt_8 peek(alt_u16 addr, alt_u8 len) {

	wData[0] = (alt_u8)(addr >> 8);
	wData[1] = (alt_u8)(addr & 0x0FF);

	camera_i2c_status = alt_avalon_i2c_master_tx_rx(camera_i2c_dev,wData, 2, rData, len, ALT_AVALON_I2C_NO_INTERRUPTS);
	if (camera_i2c_status != ALT_AVALON_I2C_SUCCESS) {
		alt_putstr("Error Reading from MIRA220\r\n");
		return 1;
	}
	return 0;
}

/****************************************************************************/
// init_MIRA220 : Initialize VVP components and MIRA220 Camera for 1600x1400
/****************************************************************************/
alt_u8 init_MIRA220 () {

	// Initialize the White Balance Correction, in LITE mode
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_WBC_BASE,WBC_CONTROL, (0x03 << 1));			// CONTROL.PHASE
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_WBC_BASE,WBC_IMG_WIDTH,1280);				// IMG_INFO_WIDTH
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_WBC_BASE,WBC_IMG_HEIGHT,720);				// IMG_INFO_HEIGHT
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_WBC_BASE,WBC_CFA_00_COLOR_SCALER,(2048 * 111 /100));	// CFA_00_COLOR_SCALER
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_WBC_BASE,WBC_CFA_01_COLOR_SCALER,(2048 * 110 /100));	// CFA_01_COLOR_SCALER
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_WBC_BASE,WBC_CFA_10_COLOR_SCALER,(2048 * 110 /100));	// CFA_10_COLOR_SCALER
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_WBC_BASE,WBC_CFA_11_COLOR_SCALER,(2048 * 108 /100));	// CFA_11_COLOR_SCALER
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_WBC_BASE,WBC_COMMIT,0x01);		// COMMIT

	// demosaic IP configuration
    // In LITE mode
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_DEMOSAIC_BASE,DEMOSAIC_IMG_WIDTH,1280);
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_DEMOSAIC_BASE,DEMOSAIC_IMG_HEIGHT,720);
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_DEMOSAIC_BASE,DEMOSAIC_CONTROL,0x02);

	// Initialize the Scaler
    // In LITE mode
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_SCALER_BASE,0x120,1280);	// IMG_INFO_WIDTH
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_SCALER_BASE,0x124,720);	// IMG_INFO_HEIGHT
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_SCALER_BASE,0x148,320);	// OUTPUT_WIDTH
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_SCALER_BASE,0x14C,200);	// OUTPUT_HEIGHT

	//alt_putstr("Initializing Video Frame Writer\r\n");
	// Write image dimensions
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VVP_VFW_IMG_WIDTH, (320*3));	// IMG_INFO_WIDTH
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VVP_VFW_IMG_HEIGHT, 200);		// IMG_INFO_HEIGHT
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VVP_VFW_NUM_BUFFERS, 0x01);	// Num Buffers
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VVP_VFW_BUFFER_BASE, MIPI_SYSTEM_0_VID_FRAME_BUF_BASE);	// BUFFER_BASE
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VVP_VFW_INTER_BUFFER_OFFSET, 0x30000);	// BUFFER SPACING
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VVP_VFW_INTER_LINE_OFFSET, (320*3));	// LINE SPACING
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VFW_IRQ_CONTROL, 0x01);	// Field Write IRQ bit

	// Commit writes
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VVP_VFW_RUN, 0x01);	// RUN (free-running)
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VVP_VFW_COMMIT, 0x01);	// COMMIT
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VFW_BUFFER_ACKNOWLEDGE,0x00);	// BUFFER_ACKNOWLEDGE


    // Camera On
    IOWR_ALTERA_AVALON_PIO_DATA(NIOSV_SYSTEM_0_PIO_MIPI_BASE, MIRA220_ENABLE);
    usleep (500000);
    usleep (500000);

    // Assert MIRA220 SW Reset
	//{0x5004, 0x01},
    poke (MIRA220_MIPI_SOFT_RESET_REG,MIRA220_MIPI_SOFT_RESET_DPHY,1);
    usleep (500000);
    // Remove SW Reset
	//{0x5004, 0x00},
    poke (MIRA220_MIPI_SOFT_RESET_REG,MIRA220_MIPI_SOFT_RESET_NONE,1);

	// write selected registers
	alt_putstr("\r\nInitializing MIRA220 for 1280x720 Mode Registers ");
	for (int i = 0; i < sizeof(full_1500mbps_1280_720_30fps_12b_2lanes_reg)/sizeof(struct mira220_reg); i++)
	{
		poke(full_1500mbps_1280_720_30fps_12b_2lanes_reg[i].address, full_1500mbps_1280_720_30fps_12b_2lanes_reg[i].val, 1);
		//alt_putchar('.');
	}

	// set exposure
	poke(MIRA220_REG_EXPOSURE,   exp_time[exp_time_index] & 0x0FF, 1);
	poke(MIRA220_REG_EXPOSURE+1, exp_time[exp_time_index] >> 8, 1);

	//usleep (500000);

	//Software Trigger.IMAGER_RUN(0)
	poke(MIRA220_IMAGER_STATE_REG,MIRA220_MASTER_EXPOSURE,1);

	poke(MIRA220_IMAGER_RUN_REG,MIRA220_IMAGER_RUN_START,1);
    usleep (500000);

    // Register the interrupt handlers
	alt_ic_isr_register (MIPI_SYSTEM_0_VVP_VFW_IRQ_INTERRUPT_CONTROLLER_ID, MIPI_SYSTEM_0_VVP_VFW_IRQ, VFW_isr, NULL, NULL);
	// Enable VFW IRQ in the Interrupt Controller
	alt_ic_irq_enable (MIPI_SYSTEM_0_VVP_VFW_IRQ_INTERRUPT_CONTROLLER_ID, MIPI_SYSTEM_0_VVP_VFW_IRQ);

	return 0;
}


/* Convert a Hex nibble into an ASCII character */
char HEX2ASCII (char HEX_IN)
{
  char a_TEMP, h_TEMP;

  // shift upper nibble down
  h_TEMP = HEX_IN;
  if (h_TEMP == 0x0A)
    a_TEMP = 'A';
  else if (h_TEMP == 0x0B)
    a_TEMP = 'B';
  else if (h_TEMP == 0x0C)
    a_TEMP = 'C';
  else if (h_TEMP == 0x0D)
    a_TEMP = 'D';
  else if (h_TEMP == 0x0E)
    a_TEMP = 'E';
  else if (h_TEMP == 0x0F)
    a_TEMP = 'F';
  else
    a_TEMP = 0x30 + h_TEMP;

  return a_TEMP;
}

void byte2bcd (char value)
{
	unsigned char rem2, bcd2, bcd1, bcd0;

	// Convert Byte data to 3 BCD characters (ASCII)
	bcd2 = value / 100;
	rem2 = value % 100;
	bcd1 = rem2 / 10;
	bcd0 = rem2 % 10;
	if (bcd2 != 0) alt_putchar(HEX2ASCII(bcd2));
	if (bcd1 != 0) alt_putchar(HEX2ASCII(bcd1));
	alt_putchar(HEX2ASCII(bcd0));
}

void byte2bcd4 (alt_u16 value)
{
	unsigned char bcd3, bcd2, bcd1, bcd0;
	alt_u16 rem3, rem2;

	// Convert Byte data to 4 BCD characters (ASCII)
	bcd3 = value / 1000;
	rem3 = value % 1000;
	bcd2 = rem3 / 100;
	rem2 = rem3 % 100;
	bcd1 = rem2 / 10;
	bcd0 = rem2 % 10;
	if (bcd3 != 0) {
		alt_putchar(HEX2ASCII(bcd3));
	} else {
		alt_putchar(' ');
	}
	if ((bcd3 != 0) || (bcd2 != 0)) {
		alt_putchar(HEX2ASCII(bcd2));
	} else {
		alt_putchar(' ');
	}
	if ((bcd3 != 0) || (bcd2 != 0) || (bcd1 != 0)) {
		alt_putchar(HEX2ASCII(bcd1));
	} else {
		alt_putchar(' ');
	}
	alt_putchar(HEX2ASCII(bcd0));
}

void word2ascii (alt_u16 value)
{
	alt_putchar(HEX2ASCII(value >> 12));
	alt_putchar(HEX2ASCII((value >> 8) & 0x0F));
	alt_putchar(HEX2ASCII((value >> 4) & 0x0F));
	alt_putchar(HEX2ASCII((value     ) & 0x0F));

}

void long_word2ascii (alt_u32 value)
{
	alt_putchar(HEX2ASCII(value >> 28));
	alt_putchar(HEX2ASCII((value >> 24) & 0x0F));
	alt_putchar(HEX2ASCII((value >> 20) & 0x0F));
	alt_putchar(HEX2ASCII((value >> 16) & 0x0F));
	alt_putchar(HEX2ASCII((value >> 12) & 0x0F));
	alt_putchar(HEX2ASCII((value >> 8) & 0x0F));
	alt_putchar(HEX2ASCII((value >> 4) & 0x0F));
	alt_putchar(HEX2ASCII((value     ) & 0x0F));

}

// ***********************************************************
// dump_vfb - dump the RGB data from the video buffer
//          - 320x200 * 8bpc * 3 colors = 192,000 bytes
// *************************************************************

void dump_vfb ()
{

alt_u32 offset;
alt_u32 mem_data;

	//fopen("/mnt/c/users/A91399/datafile.dat", "wa");
	// Stop VFW from writing to VFB
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VVP_VFW_RUN, 0x00);	// RUN (free-running)
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VVP_VFW_COMMIT, 0x01);	// COMMIT
	usleep(100000);

	alt_putstr("\r\n24-bit per color:\r\n");

	for (offset = 0; offset < 1024; offset+=4)
	{
		mem_data = IORD_32DIRECT(MIPI_SYSTEM_0_VID_FRAME_BUF_BASE,offset);
		long_word2ascii(mem_data);
		alt_putstr("\r\n");
	}
	alt_putstr("\r\n\n");

	// Commit writes
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VVP_VFW_RUN, 0x01);	// RUN (free-running)
	IOWR_32DIRECT (MIPI_SYSTEM_0_VVP_VFW_BASE,VVP_VFW_COMMIT, 0x01);	// COMMIT
}

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

// =============================================================
// VFW_isr - Video Frame Writer interrupt service routine.
//           Happens every time the VFW writes a frame
//           Acknowledge the buffer
//          PB[3]/S4 toggles Red FPGA_LED1 every press
//
void VFW_isr (void* context)
{

	//alt_u32 buffer_start_addr;

    IOWR_ALTERA_AVALON_PIO_DATA(NIOSV_SYSTEM_0_PIO_LED_BASE, 0x06);  // only B on
	alt_putstr("In VFW IRQ\r\n");

	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_VFW_BASE,VFW_BUFFER_ACKNOWLEDGE,0x00);	// BUFFER_ACKNOWLEDGE

	// Clear the interrupt bit
	IOWR_32DIRECT(MIPI_SYSTEM_0_VVP_VFW_BASE,VFW_IRQ_STATUS,0x01);	// IRQ_STATUS
}


/* =============================================================
 * PB_isr - Push-Button interrupt service routine.
 *          Happens every time the buttons is pressed
 *          USER_PB (S2)
 */
void PB_isr (void* context)
{
   alt_u8 new_pb;

   // wait ~20msec debounce time
   usleep(20*1000);
   new_pb = (IORD_ALTERA_AVALON_PIO_DATA(NIOSV_SYSTEM_0_PIO_PB_BASE) & 0x01);

   // If PB
   if (new_pb != 0x01) {  // enter only if a button is still pressed

#ifdef debug
    	  alt_putstr("USER_PB pressed\r\n");
#endif
    	  if (exp_time_index != 12) {
    		exp_time_index++;
    	  } else {
      		exp_time_index = 0;;
    	  }
    		// set exposure
    		poke(MIRA220_REG_EXPOSURE,   exp_time[exp_time_index] & 0x0FF, 1);
    		poke(MIRA220_REG_EXPOSURE+1, exp_time[exp_time_index] >> 8, 1);
   }
   // Clear both interrupt bits
   IOWR_ALTERA_AVALON_PIO_EDGE_CAP(NIOSV_SYSTEM_0_PIO_PB_BASE, 0x01);
}




