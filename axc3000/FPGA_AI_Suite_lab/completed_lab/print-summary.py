
from torchinfo import summary
from model_mnist import*

model = Net()
batch_size = 16
summary(model, input_size=(1, 1, 28, 28))


