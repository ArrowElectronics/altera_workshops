
# run
dla_compiler \
--batch-size=1 \
--network-file ../Digit-classifier.xml \
--march ../AGX5_Streaming_Ddrfree_Softmax.arch \
--foutput-format=open_vino_hetero \
--o lenet-bin.bin \
--fplugin HETERO:FPGA \
--dumpdir ./lenet-dlac-out/

# sw emu
mkdir coredla-work
cd coredla-work
source dla_init_local_directory.sh

cd $COREDLA_WORK/runtime
rm -rf build_Release
./build_runtime.sh -target_emulation
cd ..
mkdir work
cd work

$COREDLA_WORK/runtime/build_Release/dla_benchmark/dla_benchmark \
-b 1 \
-niter 1 \
-nireq 1 \
-m ../Digit-classifier.xml \
-d HETERO:FPGA \
-streaming_input_pipe pipe \
-arch_file ../AGX5_Streaming_Ddrfree_Softmax.arch \
-dump_output \
-plugins emulation -dump_output


# Once the above command is waiting for input, in another terminal window:
cat ./array_hwc_fp16.bin > pipe


