# converter_mnist.py
# Anaconda3-2020.02 - Python 3.7.6

import numpy as np
import matplotlib.pyplot as plt

# convert MNIST binary to text file; combine pixels and labels
# target format:
# pixel_1 (tab) pixel_2 (tab) . . pixel_784 (tab) digit

# 1. manually download four zipped-binary files from
#    yann.lecun.com/exdb/mnist/ 
# 2. use 7-Zip to unzip files, add ".bin" extension
# 3. determine format you want and modify script

def convert(img_file, label_file, txt_file, n_images):
  print("\nOpening binary pixels and labels files ")
  lbl_f = open(label_file, "rb")   # MNIST has labels (digits)
  img_f = open(img_file, "rb")     # and pixel vals separate
  print("Opening destination text file ")
  txt_f = open(txt_file, "w")      # output file to write to

  print("Discarding binary pixel and label files headers ")
  img_f.read(16)   # discard header info
  lbl_f.read(8)    # discard header info

  print("\nReading binary files, writing to text file ")
  print("Format: 784 pixel vals then label val, tab delimited ")
  for i in range(n_images):   # number images requested 
    lbl = ord(lbl_f.read(1))  # get label (unicode, one byte) 
    for j in range(784):  # get 784 vals from the image file
      val = ord(img_f.read(1))
      txt_f.write(str(val) + "\t") 
    txt_f.write(str(lbl) + "\n")
  img_f.close(); txt_f.close(); lbl_f.close()
  print("\nDone ")

def display_from_file(txt_file, idx):
  all_data = np.loadtxt(txt_file, delimiter="\t",
    usecols=range(0,785), dtype=np.int64)

  x_data = all_data[:,0:784]  # all rows, 784 cols
  y_data = all_data[:,784]    # all rows, last col

  label = y_data[idx]
  print("digit = ", str(label), "\n")

  pixels = x_data[idx]
  pixels = pixels.reshape((28,28))
  for i in range(28):
    for j in range(28):
      # print("%.2X" % pixels[i,j], end="")
      print("%3d" % pixels[i,j], end="")
      print(" ", end="")
    print("")

  plt.tight_layout()
  plt.imshow(pixels, cmap=plt.get_cmap('gray_r'))
  plt.show()  

# -----------------------------------------------------------

import torch as T
device = T.device('cpu')

class MNIST_Dataset(T.utils.data.Dataset):
  # 784 tab-delim pixel values (0-255) then label (0-9)
  def __init__(self, src_file, n_rows=None):
    all_xy = np.loadtxt(src_file, max_rows=n_rows,
      usecols=range(785), delimiter="\t",
      skiprows=0, comments="#", dtype=np.float32)

    tmp_x = all_xy[:, 0:784]  # all rows, cols [0,783]
    tmp_x /= 255
    tmp_x = tmp_x.reshape(-1, 1, 28, 28)  # len, chnl, 28x28
    tmp_y = all_xy[:, 784]    # 1-D required

    self.x_data = \
      T.tensor(tmp_x, dtype=T.float32).to(device)
    self.y_data = \
      T.tensor(tmp_y, dtype=T.int64).to(device) 

  def __len__(self):
    return len(self.x_data)

  def __getitem__(self, idx):
    lbl = self.y_data[idx]  # no use labels
    pixels = self.x_data[idx] 
    # return (lbl, pixels)
    # return pixels
    return (pixels, lbl)

# -----------------------------------------------------------

def main():
  n_images = 1000
  print("\nCreating %d MNIST train images from binary files " % n_images)
  convert("./UnzippedBinary/train-images.idx3-ubyte.bin",
          "./UnzippedBinary/train-labels.idx1-ubyte.bin",
          "mnist_train_1000.txt", 1000)

  # n_images = 100
  # print("\nCreating %d MNIST test images from binary files " % n_images)
  # convert(".\\UnzippedBinary\\t10k-images.idx3-ubyte.bin",
  #         ".\\UnzippedBinary\\t10k-labels.idx1-ubyte.bin",
  #         "mnist_test_100.txt", 100)

  print("\nShowing train image [0]: ")
  img_file = "./mnist_train_1000.txt"
  display_from_file(img_file, idx=0)  # first image
  
  train_ds = MNIST_Dataset("./mnist_train_1000.txt")
  train_ldr = T.utils.data.DataLoader(train_ds,
    batch_size=2, shuffle=False)
  for (batch_idx, batch) in enumerate(train_ldr):
    (X, y) = batch
    print(X)
    print(y)
    input()

  # f = open(".\\mnist_train_1000.txt", "r")
  # for line in f:
  #   print(line)
  #   input()
  # f.close()

if __name__ == "__main__":
  main()
