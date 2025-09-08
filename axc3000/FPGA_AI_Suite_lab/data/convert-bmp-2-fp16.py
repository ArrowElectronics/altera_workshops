import sys
from PIL import Image
import numpy as np

def convert_image_to_bin(input_image_name):
	# Read the BMP file
	img = Image.open(input_image_name)
	output_file_name = 'array_hwc_fp16.bin'
	# Convert the image to a numpy array
	arr = np.array(img)
	# Convert the image to FP16 format
	arr_fp16 = arr.astype(np.float16)
	# Save the FP16 HWC formatted data to a .bin file
	with open(output_file_name, 'wb') as f:
		arr_fp16.tofile(f)
	print(f"Converted {input_image_name} to {output_file_name}")

if __name__ == "__main__":
	if len(sys.argv) != 2:
		print("Usage: python bmp_to_bin_converter.py <input_image_name>")
		sys.exit(1)
	input_image_name = sys.argv[1]
	convert_image_to_bin(input_image_name)


