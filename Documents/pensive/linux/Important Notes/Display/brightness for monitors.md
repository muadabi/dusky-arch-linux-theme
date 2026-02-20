### Installing required packages

```bash
sudo pacman -S ddcutil i2c-tools
```

### Enable I2C Access

```bash
# Load kernel module
sudo modprobe i2c-dev

# Make persistent
echo "i2c-dev" | sudo tee /etc/modules-load.d/i2c.conf

# Add user to i2c group (log out/in after)
sudo usermod -aG i2c $USER
sudo sh -c 'echo "KERNEL==\"i2c-[0-9]*\", GROUP=\"i2c\", MODE=\"0660\"" > /etc/udev/rules.d/99-i2c.rules'
sudo udevadm control --reload-rules && sudo udevadm trigger

# Verify Your Monitor Supports DDC/CI
ddcutil detect

# Test Brightness Control

# Check current brightness
ddcutil --display 1 getvcp 10

# Set brightness to 50%
ddcutil --display 1 setvcp 10 50

```
