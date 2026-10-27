BUILD_DIR := bin
TARGET    := $(BUILD_DIR)/juniper
OBJ       := $(BUILD_DIR)/juniper.o

build: $(TARGET)

$(TARGET): $(OBJ)
	ld -o $@ $<

$(OBJ): juniper.asm | $(BUILD_DIR)
	nasm -f elf64 -o $@ $<

$(BUILD_DIR):
	mkdir -p $@

run: $(TARGET)
	./$(TARGET)

clean:
	rm -rf $(BUILD_DIR)

help:
	@echo "Targets:"
	@echo " - build	; build the executable (default)"
	@echo " - run	; build and run"
	@echo " - clean	; delete build directory"

.PHONY: build run clean help
