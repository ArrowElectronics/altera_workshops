@echo on

echo
echo "*** Convert paint image from BMP to FP16 binary format ***"
echo

@echo off
python convert_bmp_2_bin_fp16.py digit.bmp digit.bin

@echo on

echo
echo "*** Display image ***"
echo

@echo off
python display-fp16-file.py digit.bin

@echo on

echo
echo "*** Run inference on FPGA using system console ***"
echo

@echo off
system-console.exe --script=system_console_script.tcl --input digit.bin --num_inferences 1 --output_shape [10 1 1] --functional --arch ../AGX5_Streaming_Ddrfree_Softmax.arch

@echo on

echo
echo "*** Post process inference results and display them ***"
echo

@echo off
python streaming_post_processing.py output1.bin

@echo on

echo
echo "*** Display inference results ***"
echo

@echo off
type result_hw.txt
