// Test-only (never linked into a player): recover the ISO AAC Huffman codebooks by running the Apache-2.0
// PacketVideo lookup decoder over every input of each book's maximum length.
#include <cstdio>
#include <cstring>
#include <vector>
#include "pv_audio_type_defs.h"
#include "s_bits.h"
#include "huffman.h"
typedef Int (*dec)(BITS *);
int main(){
  struct {const char *name; dec f; int len; int symbols;} books[] = {
    {"1", decode_huff_cw_tab1, 11, 81}, {"2", decode_huff_cw_tab2, 9, 81},
    {"3", decode_huff_cw_tab3, 16, 81}, {"4", decode_huff_cw_tab4, 12, 81},
    {"5", decode_huff_cw_tab5, 13, 81}, {"6", decode_huff_cw_tab6, 11, 81},
    {"7", decode_huff_cw_tab7, 12, 64}, {"8", decode_huff_cw_tab8, 10, 64},
    {"9", decode_huff_cw_tab9, 15, 169}, {"10", decode_huff_cw_tab10, 12, 169},
    {"11", decode_huff_cw_tab11, 12, 289}, {"scl", decode_huff_scl, 19, 121}};
  for (auto &b : books) {
    std::vector<long> code(b.symbols, -1); std::vector<int> length(b.symbols, 0);
    unsigned char buffer[8];
    for (long v = 0; v < (1L << b.len); v++) {
      unsigned long x = (unsigned long)v << (32 - b.len);
      memset(buffer, 0, sizeof buffer);
      for (int i = 0; i < 4; i++) buffer[i] = x >> (24 - 8 * i);
      BITS s = {buffer, 0, 64, 8, 0};
      int symbol = b.f(&s);
      int used = s.usedBits;
      if (symbol < 0 || symbol >= b.symbols || used < 1 || used > b.len) { fprintf(stderr, "book %s bad %ld\n", b.name, v); return 1; }
      long prefix = v >> (b.len - used);
      if (code[symbol] == -1) { code[symbol] = prefix; length[symbol] = used; }
      else if (code[symbol] != prefix || length[symbol] != used) { fprintf(stderr, "book %s symbol %d two codes\n", b.name, symbol); return 1; }
    }
    double kraft = 0; int maxlen = 0;
    for (int i = 0; i < b.symbols; i++) { if (code[i] < 0) { fprintf(stderr, "book %s missing %d\n", b.name, i); return 1; } kraft += 1.0 / (1L << length[i]); if (length[i] > maxlen) maxlen = length[i]; }
    if (kraft != 1.0) { fprintf(stderr, "book %s kraft %f\n", b.name, kraft); return 1; }
    printf("book %s %d %d", b.name, b.symbols, maxlen);
    for (int i = 0; i < b.symbols; i++) printf(" %d:%lx", length[i], code[i]);
    printf("\n");
  }
  return 0;
}
