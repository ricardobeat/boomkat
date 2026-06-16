// CHIP-8 emulator — IBM logo ROM test
// Exercises: classes, arrays, bitwise ops, switch, for loops

class Chip8 {
    constructor() {
        this.mem = [];
        this.v = [];
        this.i = 0;
        this.pc = 0x200;
        this.stack = [];
        this.display = [];

        for (let idx = 0; idx < 4096; idx++) this.mem[idx] = 0;
        for (let idx = 0; idx < 16; idx++) this.v[idx] = 0;
        for (let idx = 0; idx < 64 * 32; idx++) this.display[idx] = 0;
    }

    loadRom(rom) {
        for (let idx = 0; idx < rom.length; idx++) {
            this.mem[0x200 + idx] = rom[idx];
        }
    }

    cycle() {
        let opcode = (this.mem[this.pc] << 8) | this.mem[this.pc + 1];
        this.pc += 2;

        let nnn = opcode & 0x0FFF;
        let nn = opcode & 0x00FF;
        let n = opcode & 0x000F;
        let x = (opcode >> 8) & 0x0F;
        let y = (opcode >> 4) & 0x0F;

        switch (opcode >> 12) {
            case 0x0:
                if (opcode === 0x00E0) {
                    for (let idx = 0; idx < 64 * 32; idx++) this.display[idx] = 0;
                } else if (opcode === 0x00EE) {
                    this.pc = this.stack.pop();
                }
                break;
            case 0x1:
                this.pc = nnn;
                break;
            case 0x2:
                this.stack.push(this.pc);
                this.pc = nnn;
                break;
            case 0x3:
                if (this.v[x] === nn) this.pc += 2;
                break;
            case 0x4:
                if (this.v[x] !== nn) this.pc += 2;
                break;
            case 0x5:
                if (this.v[x] === this.v[y]) this.pc += 2;
                break;
            case 0x6:
                this.v[x] = nn;
                break;
            case 0x7:
                this.v[x] = (this.v[x] + nn) & 0xFF;
                break;
            case 0x8:
                switch (n) {
                    case 0x0: this.v[x] = this.v[y]; break;
                    case 0x1: this.v[x] = this.v[x] | this.v[y]; break;
                    case 0x2: this.v[x] = this.v[x] & this.v[y]; break;
                    case 0x3: this.v[x] = this.v[x] ^ this.v[y]; break;
                    case 0x4: {
                        let sum = this.v[x] + this.v[y];
                        this.v[0xF] = sum > 255 ? 1 : 0;
                        this.v[x] = sum & 0xFF;
                        break;
                    }
                    case 0x5: {
                        this.v[0xF] = this.v[x] > this.v[y] ? 1 : 0;
                        this.v[x] = (this.v[x] - this.v[y]) & 0xFF;
                        break;
                    }
                    case 0x6: {
                        this.v[0xF] = this.v[x] & 1;
                        this.v[x] = this.v[x] >> 1;
                        break;
                    }
                    case 0x7: {
                        this.v[0xF] = this.v[y] > this.v[x] ? 1 : 0;
                        this.v[x] = (this.v[y] - this.v[x]) & 0xFF;
                        break;
                    }
                    case 0xE: {
                        this.v[0xF] = (this.v[x] >> 7) & 1;
                        this.v[x] = (this.v[x] << 1) & 0xFF;
                        break;
                    }
                }
                break;
            case 0x9:
                if (this.v[x] !== this.v[y]) this.pc += 2;
                break;
            case 0xA:
                this.i = nnn;
                break;
            case 0xB:
                this.pc = nnn + this.v[0];
                break;
            case 0xC:
                this.v[x] = (Math.floor(Math.random() * 256)) & nn;
                break;
            case 0xD: {
                this.v[0xF] = 0;
                let xPos = this.v[x] & 63;
                let yPos = this.v[y] & 31;
                for (let row = 0; row < n; row++) {
                    let py = yPos + row;
                    if (py >= 32) break;
                    let spriteByte = this.mem[this.i + row];
                    for (let col = 0; col < 8; col++) {
                        let px = xPos + col;
                        if (px >= 64) break;
                        if ((spriteByte & (0x80 >> col)) !== 0) {
                            let idx = py * 64 + px;
                            if (this.display[idx] === 1) this.v[0xF] = 1;
                            this.display[idx] = this.display[idx] ^ 1;
                        }
                    }
                }
                break;
            }
        }
    }

    render() {
        let out = "";
        for (let y = 0; y < 32; y++) {
            let line = "";
            for (let x = 0; x < 64; x++) {
                line += this.display[y * 64 + x] ? "##" : "  ";
            }
            out += line + "\n";
        }
        return out;
    }
}

// IBM Logo ROM (132 bytes) — the classic CHIP-8 first test
var rom = [
    0x00, 0xE0, 0xA2, 0x2A, 0x60, 0x0C, 0x61, 0x08, 0xD0, 0x1F, 0x70, 0x09, 0xA2, 0x39, 0xD0, 0x1F,
    0xA2, 0x48, 0x70, 0x08, 0xD0, 0x1F, 0x70, 0x04, 0xA2, 0x57, 0xD0, 0x1F, 0x70, 0x08, 0xA2, 0x66,
    0xD0, 0x1F, 0x70, 0x08, 0xA2, 0x75, 0xD0, 0x1F, 0x12, 0x28, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80,
    0x80, 0x80, 0x80, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0xFF, 0xFC, 0x00, 0x82, 0x00, 0x82, 0x00, 0x82, 0xFF, 0xFC, 0x80, 0x00, 0x80,
    0x00, 0x80, 0x00, 0x80, 0x00, 0xFF, 0xFC, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFC, 0x02, 0x84, 0x02, 0x84, 0x02, 0x84, 0x02,
    0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00
];

var emu = new Chip8();
emu.loadRom(rom);

// 6 draw sequences at 4 instructions each, plus CLS + JMP overhead
for (let cycle = 0; cycle < 40; cycle++) {
    emu.cycle();
}

console.log("=== CHIP-8 IBM Logo ===");
console.log(emu.render());

// Count lit pixels and verify
let pixelCount = 0;
for (let idx = 0; idx < 64 * 32; idx++) {
    if (emu.display[idx] === 1) pixelCount++;
}
console.log("Pixels lit: " + pixelCount);
console.log(pixelCount > 50 ? "PASS" : "FAIL");
