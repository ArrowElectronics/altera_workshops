#!/bin/bash
set -x

# steps for regen ip
rm -rf ./build-agx5-lenet/coredla_ip
rm -rf ./build-agx5-lenet/hw/coredla_ip
rm -rf ./dlac-out

# regen dlac for parameter rom
# Remove folding option if using 2025.1, needed for 2025.1.1 with LW LT
dlac \
--network-file ./Digit-classifier.xml \
--march ./AGX5_Streaming_Ddrfree_Softmax-2025.1.1.arch \
--foutput-format=open_vino_hetero \
--o digit_classifier-bin.bin \
--fplugin HETERO:FPGA \
--dumpdir ./dlac-out/ \
--ffolding-option 0 \
--fanalyze-performance --fanalyze-area

# gen ip
dla_create_ip \
--flow create_ip \
--arch ./AGX5_Streaming_Ddrfree_Softmax.arch \
--ip_dir ./build-agx5-lenet/coredla_ip \
--parameter_rom_dir ./dlac-out/parameter_rom/ --licensed

# compile project
pushd .
cd ./build-agx5-lenet/hw
cp -r ../coredla_ip ./coredla_ip
quartus_sh --flow compile top
cp output_files/top.sof ../
popd

set +x

