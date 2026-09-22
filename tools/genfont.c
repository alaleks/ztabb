// Bakes an antialiased bitmap font from a system monospace face via CoreText.
//
// Emits two files, both committed so the build itself needs neither this tool
// nor macOS:
//   src/font.dat      raw 8-bit coverage, one byte per pixel
//   src/font_data.zig metrics and the codepoint->glyph index table
//
// Two cell sizes are baked. A glyph bitmap upscaled to a HiDPI backbuffer
// looks like it was typed on a typewriter, so the 2x set is rasterized at its
// own resolution rather than stretched from the 1x one.
//
//   cc -O2 -o genfont tools/genfont.c -framework CoreText -framework CoreGraphics \
//      -framework CoreFoundation && ./genfont
//
// Pass codepoints as arguments to dump them as ASCII art instead.

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Weight bits. Menlo ships Regular and Bold only, so `medium` (weight 500) is
// synthesized by stroking the regular outline: controllable, and closer to 500
// than either real face.
#define W_REGULAR 1
#define W_BOLD    2
#define W_MEDIUM  4

typedef struct { int w, h; int weights; } Cell;

// Terminal cells at 1x and 2x, plus the smaller sizes the tab bar and dialogs
// set their labels in. font.zig picks the largest set that fits the box it is
// drawing into.
static const Cell cells[] = {
    {6, 12, W_MEDIUM},            // UI text, 1x
    {8, 16, W_REGULAR | W_BOLD},  // terminal, 1x
    {12, 24, W_MEDIUM},           // UI text, 2x
    {16, 32, W_REGULAR | W_BOLD}, // terminal, 2x
};
#define NCELLS ((int)(sizeof(cells) / sizeof(cells[0])))

static const char *weight_name(int bit) {
    return bit == W_REGULAR ? "regular" : bit == W_BOLD ? "bold" : "medium";
}

typedef struct { unsigned int lo, hi; } Range;

static const Range ranges[] = {
    {0x0020, 0x007E}, // ASCII printable
    {0x00A0, 0x00FF}, // Latin-1 supplement
    {0x0400, 0x045F}, // Cyrillic
    {0x2010, 0x2027}, // dashes, quotes, bullet, ellipsis
    {0x2190, 0x21AF}, // arrows
    {0x2500, 0x257F}, // box drawing
    {0x2580, 0x259F}, // block elements
    {0x25A0, 0x25FF}, // geometric shapes
    {0x2600, 0x27BF}, // misc symbols and dingbats (agnoster uses several)
    {0xE0A0, 0xE0B3}, // Powerline: branch, padlock, separators
};
static const int nranges = sizeof(ranges) / sizeof(ranges[0]);

// Block elements are pure geometry, and Menlo's outlines do not line up with a
// character cell (its full block leaves blank rows). Draw them by hand so
// adjacent cells tile seamlessly.
static int blockGlyph(unsigned int cp, int w, int h, unsigned char *out) {
    if (cp < 0x2580 || cp > 0x259F) return 0;
    memset(out, 0, (size_t)w * h);

    // Proportional, not integer eighths: at 12 rows `h / 8` is 1, so eight of
    // them cover two thirds of the cell instead of all of it.
    #define EIGHTH_H(n) ((h) * (n) / 8)
    #define EIGHTH_W(n) ((w) * (n) / 8)
    #define FILL(x0, y0, x1, y1)                                    \
        for (int y = (y0); y < (y1); y++)                           \
            for (int x = (x0); x < (x1); x++) out[y * w + x] = 255

    if (cp == 0x2580) { FILL(0, 0, w, h / 2); return 1; }
    if (cp >= 0x2581 && cp <= 0x2588) {          // lower 1/8 .. full block
        int rows = EIGHTH_H((int)(cp - 0x2580));
        FILL(0, h - rows, w, h);
        return 1;
    }
    if (cp >= 0x2589 && cp <= 0x258F) {          // left 7/8 .. left 1/8
        int cols = EIGHTH_W(8 - (int)(cp - 0x2588));
        FILL(0, 0, cols, h);
        return 1;
    }
    if (cp == 0x2590) { FILL(w / 2, 0, w, h); return 1; }
    if (cp >= 0x2591 && cp <= 0x2593) {          // 25% / 50% / 75% shade
        // A flat coverage value beats a dither pattern now that the font is
        // antialiased: it reads as an even tint at any cell size.
        unsigned char v = (cp == 0x2591) ? 64 : (cp == 0x2592) ? 128 : 191;
        memset(out, v, (size_t)w * h);
        return 1;
    }
    if (cp == 0x2594) { FILL(0, 0, w, EIGHTH_H(1) > 0 ? EIGHTH_H(1) : 1); return 1; }
    if (cp == 0x2595) {
        int c = EIGHTH_W(1) > 0 ? EIGHTH_W(1) : 1;
        FILL(w - c, 0, w, h);
        return 1;
    }

    // 0x2596..0x259F: quadrants. Bit 0 = upper-left, 1 = upper-right,
    // 2 = lower-left, 3 = lower-right.
    static const unsigned char quad[10] = {
        0x4, 0x8, 0x1, 0xD, 0x9, 0x7, 0xB, 0x2, 0x6, 0xE,
    };
    unsigned char q = quad[cp - 0x2596];
    if (q & 0x1) { FILL(0, 0, w / 2, h / 2); }
    if (q & 0x2) { FILL(w / 2, 0, w, h / 2); }
    if (q & 0x4) { FILL(0, h / 2, w / 2, h); }
    if (q & 0x8) { FILL(w / 2, h / 2, w, h); }
    #undef FILL
    #undef EIGHTH_H
    #undef EIGHTH_W
    return 1;
}

// Powerline separators must line up pixel-exactly with the cells either side
// of them, which no fallback font can promise, so they are drawn here. The
// rest of the Powerline set is simple enough to draw too, and Menlo has none
// of it.
static double edgeDistance(double px, double py, double ax, double ay,
                           double bx, double by) {
    double vx = bx - ax, vy = by - ay;
    double wx = px - ax, wy = py - ay;
    double len2 = vx * vx + vy * vy;
    double t = len2 > 0 ? (wx * vx + wy * vy) / len2 : 0;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    double dx = px - (ax + t * vx), dy = py - (ay + t * vy);
    return sqrt(dx * dx + dy * dy);
}

static int insideTriangle(double px, double py, const double v[6]) {
    double d1 = (px - v[2]) * (v[1] - v[3]) - (v[0] - v[2]) * (py - v[3]);
    double d2 = (px - v[4]) * (v[3] - v[5]) - (v[2] - v[4]) * (py - v[5]);
    double d3 = (px - v[0]) * (v[5] - v[1]) - (v[4] - v[0]) * (py - v[1]);
    int neg = (d1 < 0) || (d2 < 0) || (d3 < 0);
    int pos = (d1 > 0) || (d2 > 0) || (d3 > 0);
    return !(neg && pos);
}

static int powerlineGlyph(unsigned int cp, int w, int h, unsigned char *out) {
    if (cp < 0xE0A0 || cp > 0xE0B3) return 0;
    memset(out, 0, (size_t)w * h);
    const int SS = 4;
    double stroke = w / 7.0;
    if (stroke < 1.0) stroke = 1.0;

    // Separators: a solid or outlined triangle spanning the whole cell.
    double right[6] = {0, 0, 0, (double)h, (double)w, h / 2.0};
    double left[6] = {(double)w, 0, (double)w, (double)h, 0, h / 2.0};
    const double *tri = NULL;
    int solid = 0;
    if (cp == 0xE0B0) { tri = right; solid = 1; }
    else if (cp == 0xE0B1) { tri = right; solid = 0; }
    else if (cp == 0xE0B2) { tri = left; solid = 1; }
    else if (cp == 0xE0B3) { tri = left; solid = 0; }

    if (tri) {
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int hits = 0;
                for (int sy = 0; sy < SS; sy++) {
                    for (int sx = 0; sx < SS; sx++) {
                        double px = x + (sx + 0.5) / SS;
                        double py = y + (sy + 0.5) / SS;
                        if (solid) {
                            if (insideTriangle(px, py, tri)) hits++;
                        } else {
                            // The chevron is the two slanted edges only; the
                            // vertical base belongs to the solid form.
                            double d1 = edgeDistance(px, py, tri[0], tri[1], tri[4], tri[5]);
                            double d2 = edgeDistance(px, py, tri[2], tri[3], tri[4], tri[5]);
                            if (d1 <= stroke / 2 || d2 <= stroke / 2) hits++;
                        }
                    }
                }
                out[y * w + x] = (unsigned char)(hits * 255 / (SS * SS));
            }
        }
        return 1;
    }

    // The locals here must not share names with BOX's loop variables, or a
    // PLOT(_x, _y, ...) call initializes each one from itself.
    #define PLOT(xx, yy, val)                                                \
        do {                                                                 \
            int _px = (int)(xx), _py = (int)(yy);                            \
            if (_px >= 0 && _px < w && _py >= 0 && _py < h &&                \
                out[_py * w + _px] < (val))                                  \
                out[_py * w + _px] = (val);                                  \
        } while (0)
    #define BOX(x0, y0, x1, y1)                                              \
        for (int _by = (int)(y0); _by < (int)(y1); _by++)                    \
            for (int _bx = (int)(x0); _bx < (int)(x1); _bx++)                \
                PLOT(_bx, _by, 255)

    double u = w / 8.0;   // one eighth of the cell, the drawing unit
    double v = h / 16.0;

    if (cp == 0xE0A0) {           // git branch: a stem with a fork
        double t = u < 1 ? 1 : u;
        BOX(2 * u, 4 * v, 2 * u + t, 12 * v);          // trunk
        BOX(5 * u, 4 * v, 5 * u + t, 7 * v);           // branch stem
        BOX(2 * u, 7 * v, 5 * u + t, 7 * v + t);       // crossbar
        BOX(1.5 * u, 3 * v, 3 * u, 4 * v);             // top node
        BOX(1.5 * u, 12 * v, 3 * u, 13 * v);           // bottom node
        BOX(4.5 * u, 3 * v, 6 * u, 4 * v);             // branch node
        return 1;
    }
    if (cp == 0xE0A1) {           // line number: three stacked rules
        for (int i = 0; i < 3; i++) {
            BOX(1.5 * u, (4 + 3 * i) * v, 2.5 * u, (5 + 3 * i) * v);
            BOX(3.5 * u, (4 + 3 * i) * v, 7 * u, (5 + 3 * i) * v);
        }
        return 1;
    }
    if (cp == 0xE0A2) {           // padlock: shackle over a body
        double t = u < 1 ? 1 : u;
        BOX(2 * u, 8 * v, 6 * u, 13 * v);              // body
        BOX(2.5 * u, 4 * v, 2.5 * u + t, 8 * v);       // left shackle post
        BOX(5.5 * u - t, 4 * v, 5.5 * u, 8 * v);       // right shackle post
        BOX(2.5 * u, 4 * v, 5.5 * u, 4 * v + t);       // shackle top
        return 1;
    }
    #undef PLOT
    #undef BOX
    // Unassigned codepoints in the Powerline block: leave them blank rather
    // than letting a fallback font put something arbitrary there.
    return 1;
}

static CTFontRef makeFont(const char *name, double size) {
    CFStringRef n = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    CTFontRef f = CTFontCreateWithName(n, size, NULL);
    CFRelease(n);
    return f;
}

/// The point size at which `font`'s advance width is exactly `target` pixels.
static double sizeForAdvance(const char *name, double target) {
    const double probe = 100.0;
    CTFontRef f = makeFont(name, probe);
    UniChar m = 'M';
    CGGlyph g = 0;
    CTFontGetGlyphsForCharacters(f, &m, &g, 1);
    CGSize adv;
    CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, &g, &adv, 1);
    CFRelease(f);
    if (adv.width <= 0) return target / 0.6;
    return probe * target / adv.width;
}

/// Rasterizes one codepoint into `w`x`h` 8-bit coverage. Returns 0 when the
/// face has no glyph for it.
static int rasterize(CTFontRef font, unsigned int cp, int w, int h,
                     double baseline, double embolden, unsigned char *out) {
    UniChar chars[2];
    CFIndex nchars = 1;
    if (cp < 0x10000) {
        chars[0] = (UniChar)cp;
    } else {
        unsigned int v = cp - 0x10000;
        chars[0] = (UniChar)(0xD800 + (v >> 10));
        chars[1] = (UniChar)(0xDC00 + (v & 0x3FF));
        nchars = 2;
    }
    CGGlyph glyphs[2] = {0, 0};
    CTFontRef use = font;
    CTFontRef owned = NULL;
    double scale = 1.0, dx = 0.0, dy = 0.0;

    if (!CTFontGetGlyphsForCharacters(font, chars, glyphs, nchars) || glyphs[0] == 0) {
        // Menlo covers no symbols beyond the basics; ask CoreText which
        // installed face can draw this codepoint and fit its glyph to the cell.
        CFStringRef str = CFStringCreateWithCharacters(NULL, chars, nchars);
        owned = CTFontCreateForString(font, str, CFRangeMake(0, nchars));
        CFRelease(str);
        if (!owned) return 0;
        if (!CTFontGetGlyphsForCharacters(owned, chars, glyphs, nchars) || glyphs[0] == 0) {
            CFRelease(owned);
            return 0;
        }
        use = owned;
        CGRect bounds = CTFontGetBoundingRectsForGlyphs(
            use, kCTFontOrientationHorizontal, glyphs, NULL, 1);
        if (bounds.size.width <= 0 || bounds.size.height <= 0) {
            CFRelease(owned);
            return 0;
        }
        // Fit inside the cell with a small margin, then centre it.
        double margin = 0.88;
        double sx = w * margin / bounds.size.width;
        double sy = h * margin / bounds.size.height;
        scale = sx < sy ? sx : sy;
        dx = (w - bounds.size.width * scale) / 2.0 - bounds.origin.x * scale;
        dy = (h - bounds.size.height * scale) / 2.0 - bounds.origin.y * scale;
    }

    memset(out, 0, (size_t)w * h);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    // Scanlines are stored top-down even though the drawing origin is at the
    // bottom left, so the buffer can be written straight out.
    CGContextRef ctx = CGBitmapContextCreate(out, w, h, 8, w, gray, kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!ctx) return 0;

    CGContextSetGrayFillColor(ctx, 0.0, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    if (embolden > 0) {
        // Fill plus a hairline stroke in the same colour: the usual way to
        // lift a face one weight step when there is no real face to draw from.
        CGContextSetGrayStrokeColor(ctx, 1.0, 1.0);
        CGContextSetLineWidth(ctx, embolden);
        CGContextSetTextDrawingMode(ctx, kCGTextFillStroke);
    }
    CGContextSetShouldAntialias(ctx, true);
    CGContextSetShouldSmoothFonts(ctx, false); // grayscale AA, not subpixel
    CGContextSetAllowsFontSubpixelPositioning(ctx, true);
    CGContextSetShouldSubpixelPositionFonts(ctx, true);

    CGPoint pos;
    if (use == font) {
        pos = CGPointMake(0.0, baseline);
    } else {
        CGContextTranslateCTM(ctx, dx, dy);
        CGContextScaleCTM(ctx, scale, scale);
        pos = CGPointMake(0.0, 0.0);
    }
    CTFontDrawGlyphs(use, glyphs, &pos, 1, ctx);
    CGContextRelease(ctx);
    if (owned) CFRelease(owned);

    for (int i = 0; i < w * h; i++) {
        if (out[i]) return 1;
    }
    return cp == 0x20;
}

/// Lifts thin antialiased stems so small text does not wash out to grey.
static void boostContrast(unsigned char *p, int n) {
    for (int i = 0; i < n; i++) {
        double a = p[i] / 255.0;
        // gamma < 1 brightens partial coverage without touching 0 or 255
        a = pow(a, 0.72);
        int v = (int)(a * 255.0 + 0.5);
        p[i] = (unsigned char)(v > 255 ? 255 : v);
    }
}

static void dump(unsigned char *g, int w, int h, unsigned int cp) {
    static const char ramp[] = " .:-=+*#%@";
    fprintf(stderr, "U+%04X (%dx%d)\n", cp, w, h);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            fputc(ramp[g[y * w + x] * 9 / 255], stderr);
        }
        fputc('\n', stderr);
    }
}

int main(int argc, char **argv) {
    int total = 0;
    for (int i = 0; i < nranges; i++) total += (int)(ranges[i].hi - ranges[i].lo + 1);

    static const char *names[2] = {"Menlo-Regular", "Menlo-Bold"};

    if (argc > 1) {
        int w = cells[1].w, h = cells[1].h;
        double size = sizeForAdvance(names[0], w);
        CTFontRef f = makeFont(names[0], size);
        double asc = CTFontGetAscent(f), desc = CTFontGetDescent(f);
        double baseline = (h - (asc + desc)) / 2.0 + desc;
        unsigned char *g = malloc((size_t)w * h);
        for (int i = 1; i < argc; i++) {
            unsigned int cp = (unsigned int)strtol(argv[i], NULL, 0);
            if (!blockGlyph(cp, w, h, g) && !powerlineGlyph(cp, w, h, g)) {
                if (rasterize(f, cp, w, h, baseline, 0, g)) boostContrast(g, w * h);
            }
            dump(g, w, h, cp);
        }
        free(g);
        CFRelease(f);
        return 0;
    }

    FILE *dat = fopen("src/font.dat", "wb");
    if (!dat) { perror("src/font.dat"); return 1; }

    long offset = 0;
    struct { long offset; int w, h, weight; } sections[NCELLS * 3];
    int nsections = 0;

    for (int c = 0; c < NCELLS; c++) {
        int w = cells[c].w, h = cells[c].h;
        unsigned char *g = malloc((size_t)w * h);

        for (int bit = W_REGULAR; bit <= W_MEDIUM; bit <<= 1) {
            if (!(cells[c].weights & bit)) continue;

            // Medium is Menlo-Regular with a hairline stroke; the stroke is a
            // fraction of the cell so it scales with the size. Tuned so the result
            // lands between the regular and bold faces rather than beside bold.
            const char *face = (bit == W_BOLD) ? names[1] : names[0];
            double embolden = (bit == W_MEDIUM) ? w * 0.020 : 0.0;

            double size = sizeForAdvance(face, w);
            CTFontRef font = makeFont(face, size);
            CTFontRef fallback = makeFont(names[0], sizeForAdvance(names[0], w));
            if (!font) { fprintf(stderr, "%s not found\n", face); return 1; }
            double asc = CTFontGetAscent(font), desc = CTFontGetDescent(font);
            double baseline = (h - (asc + desc)) / 2.0 + desc;

            sections[nsections].offset = offset;
            sections[nsections].w = w;
            sections[nsections].h = h;
            sections[nsections].weight = bit;
            nsections++;

            int missing = 0;
            for (int i = 0; i < nranges; i++) {
                for (unsigned int cp = ranges[i].lo; cp <= ranges[i].hi; cp++) {
                    if (blockGlyph(cp, w, h, g) || powerlineGlyph(cp, w, h, g)) {
                        if (bit == W_BOLD && cp >= 0xE0A0 && cp <= 0xE0A2) {
                            // Embolden the pictograms; the separators must stay
                            // exact so they still tile.
                            for (int y = 0; y < h; y++)
                                for (int x = w - 1; x > 0; x--)
                                    if (g[y * w + x - 1] > g[y * w + x])
                                        g[y * w + x] = g[y * w + x - 1];
                        }
                        fwrite(g, 1, (size_t)w * h, dat);
                        offset += w * h;
                        continue;
                    }
                    if (rasterize(font, cp, w, h, baseline, embolden, g)) {
                        boostContrast(g, w * h);
                    } else if (bit != W_REGULAR &&
                               rasterize(fallback, cp, w, h, baseline, embolden, g)) {
                        boostContrast(g, w * h);
                        if (bit == W_BOLD) {
                            for (int y = 0; y < h; y++)
                                for (int x = w - 1; x > 0; x--)
                                    if (g[y * w + x - 1] > g[y * w + x])
                                        g[y * w + x] = g[y * w + x - 1];
                        }
                    } else {
                        memset(g, 0, (size_t)w * h);
                        missing++;
                    }
                    fwrite(g, 1, (size_t)w * h, dat);
                    offset += w * h;
                }
            }
            fprintf(stderr, "%dx%d %-8s: %d/%d blank\n",
                    w, h, weight_name(bit), missing, total);
            CFRelease(font);
            CFRelease(fallback);
        }
        free(g);
    }
    fclose(dat);

    FILE *out = fopen("src/font_data.zig", "w");
    if (!out) { perror("src/font_data.zig"); return 1; }
    fprintf(out, "// Generated by tools/genfont.c -- do not edit by hand.\n");
    fprintf(out, "// Glyph coverage lives in font.dat: %d glyphs per section,\n", total);
    fprintf(out, "// one byte per pixel, sections listed below.\n\n");
    fprintf(out, "pub const glyph_count: usize = %d;\n\n", total);
    fprintf(out, "/// 0 = regular, 1 = bold, 2 = medium.\n");
    fprintf(out, "pub const Section = struct {\n");
    fprintf(out, "    w: u32,\n    h: u32,\n    weight: u8,\n    offset: usize,\n};\n\n");
    fprintf(out, "pub const sections = [_]Section{\n");
    for (int i = 0; i < nsections; i++) {
        int wi = sections[i].weight == W_REGULAR ? 0
               : sections[i].weight == W_BOLD ? 1 : 2;
        fprintf(out, "    .{ .w = %d, .h = %d, .weight = %d, .offset = %ld },\n",
                sections[i].w, sections[i].h, wi, sections[i].offset);
    }
    fprintf(out, "};\n\n");
    fprintf(out, "pub const Range = struct { lo: u21, hi: u21, base: u16 };\n\n");
    fprintf(out, "pub const ranges = [_]Range{\n");
    int base = 0;
    for (int i = 0; i < nranges; i++) {
        fprintf(out, "    .{ .lo = 0x%04X, .hi = 0x%04X, .base = %d },\n",
                ranges[i].lo, ranges[i].hi, base);
        base += (int)(ranges[i].hi - ranges[i].lo + 1);
    }
    fprintf(out, "};\n");
    fclose(out);

    fprintf(stderr, "wrote src/font.dat (%ld bytes)\n", offset);
    return 0;
}
