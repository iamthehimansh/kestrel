#include <cstdio>

// EGL_KHR_create_context defines these three bits; zero is also valid.
constexpr unsigned allowed = 0x1u | 0x2u | 0x4u;
constexpr bool accepts(unsigned flags) { return (flags & ~allowed) == 0; }
constexpr bool oldAccepts(unsigned flags) { return (flags & allowed) != 0; }

int main() {
    for (unsigned flags = 0; flags < 256; ++flags) {
        const bool expected = flags <= allowed;
        if (accepts(flags) != expected) {
            std::fprintf(stderr, "FAIL flags=%u\n", flags);
            return 1;
        }
    }
    if (oldAccepts(0) || !oldAccepts(0x9) || accepts(0xffffffffu)) return 1;
    std::puts("PASS: zero and known combinations accepted; unknown bits rejected; old predicate fails both contracts");
    return 0;
}
