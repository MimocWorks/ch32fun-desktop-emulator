# Synthetic SSD1306 traffic: reset addressing then change all 1024 VRAM bytes.
# No CH32fun runtime dependencies. Used only by the PTY transport benchmark.
.section .text
.global _start
_start:
    li s0, 0x40005400
    li s1, 0
frame:
    li t0, 0x100
    sw t0, 0(s0)
    li t0, 0x78
    sw t0, 16(s0)
    sw zero, 16(s0)
    li t0, 0x21
    sw t0, 16(s0)
    sw zero, 16(s0)
    li t0, 127
    sw t0, 16(s0)
    li t0, 0x22
    sw t0, 16(s0)
    sw zero, 16(s0)
    li t0, 7
    sw t0, 16(s0)
    li t0, 0x200
    sw t0, 0(s0)
    li t0, 0x100
    sw t0, 0(s0)
    li t0, 0x78
    sw t0, 16(s0)
    li t0, 0x40
    sw t0, 16(s0)
    # First pixel mirrors the active-low PD1 button for PTY latency checks.
    li t2, 0x40011408
    lw t2, 0(t2)
    srli t2, t2, 1
    andi t2, t2, 1
    sw t2, 16(s0)
    li t1, 1023
pixels:
    sw s1, 16(s0)
    addi t1, t1, -1
    bnez t1, pixels
    li t0, 0x200
    sw t0, 0(s0)
    addi s1, s1, 1
    andi s1, s1, 255
    j frame
