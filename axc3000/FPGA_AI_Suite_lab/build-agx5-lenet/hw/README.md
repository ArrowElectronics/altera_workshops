# DDR-Free Design Example

## Introduction
The DDR-Free design example (Agilex 7) demonstrates how the FPGA AI-Suite can support the following: 
-	DDR-Free operation
-	Host-less operation (runtime free)
-	Streaming of input features
-	Streaming of inference results

### Components
The design example is implemented with the following components: 
-	FPGA AI Suite IP 
-	Agilex 7 I-Series Dev-kit 
-	Sample hardware and software systems that illustrate the use of these components

## Requirements 
### Hardware Requirements 
This design example requires the following hardware:
-	Agilex 7 FPGA I-Series Development Kit (Ordering Code: DK-DEV-AGI027RBES)
-	Intel FPGA Download Cable

### Software Requirements
This design example requires the following software:
-	FPGA AI Suite
-	Quartus Prime Programmer (either standalone or as part of Quartus Prime Design Suite).
-	Quartus Prime System Console (either standalone or as part of Quartus Prime Design Suite).

## DDR-Free Design Example Flow
1. Generate the parameter ROMs as .mif files by running the FPGA AI Suite compiler with a 
   ddr-free & input/output streaming architecture 
2. Build the example design with the dla_build_example_design.py command
3. Program the FPGA device with the Quartus Prime Programmer
4. Use the Quartus Prime System Console to run inference on the example design.

## Documentation
### Running Resnet18 on the Hostless DDR-Free Design Example 
Please refer to Chapter 7 of the Altera FPGA AI Suite Getting Started Guide for a step by step guide.

### DDR-Free Design Example
Please refer to the FPGA AI Suite DDR Free Design Example Documentation. 
