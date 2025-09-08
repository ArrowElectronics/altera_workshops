import numpy as np
import sys


def ascii_image(image):
	print("")
	#print(image.len)
	for i in range(28):
		for j in range(28):
			if image[(i*28)+j] > 0:
				print("*", end="")
			else:
				print("0", end="")
		print("")


def convert_fp16_binary_to_ascii(input_file):
    # Read the binary file as FP16
    data = np.fromfile(input_file, dtype=np.float16)
    
    # Write each value to the output file in ASCII format
    #with open(output_file, 'w') as f:
    #    for value in data:
    #        f.write(f"{value}\n")
    ascii_image(data)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python convert_fp16_to_ascii.py <input_file>")
        sys.exit(1)

    input_file = sys.argv[1]
    #output_file = sys.argv[2]

    convert_fp16_binary_to_ascii(input_file)


