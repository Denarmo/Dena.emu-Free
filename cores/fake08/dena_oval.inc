// SPDX-License-Identifier: MIT
// DENA_OVAL: Dena.emu's own oval()/ovalfill() for fake-08, replacing the
// upstream versions (adapted from a CC BY-SA 3.0 snippet, which GPL-3.0
// builds can't take). Written from the shape's definition: an ellipse
// inscribed in the box (x0,y0)-(x1,y1). Spec: docs/specs/pico8.md.

// Half-width of the ellipse at row y, measured from its centre column.
static double denaOvalHalfWidth(double cy, double rx, double ry, int y) {
	if (ry <= 0) return rx;
	double t = (y - cy) / (ry + 0.5);
	double s = 1.0 - t * t;
	return s <= 0 ? -1 : (rx + 0.5) * std::sqrt(s);
}

void Graphics::oval(int x0, int y0, int x1, int y1, uint8_t col) {
	color(col);
	applyCameraToPoint(&x0, &y0);
	applyCameraToPoint(&x1, &y1);
	sortCoordsForRect(&x0, &y0, &x1, &y1);
	double cx = (x0 + x1) / 2.0, cy = (y0 + y1) / 2.0;
	double rx = (x1 - x0) / 2.0, ry = (y1 - y0) / 2.0;
	// Edge pixels row by row, then column by column so steep and flat parts
	// of the outline both stay connected.
	for (int y = y0; y <= y1; y++) {
		double w = denaOvalHalfWidth(cy, rx, ry, y);
		if (w < 0) continue;
		int l = (int)std::floor(cx - w + 0.5), r = (int)std::floor(cx + w + 0.5);
		if (l < x0) l = x0;
		if (r > x1) r = x1;
		_safeSetPixelFromPen(l, y);
		_safeSetPixelFromPen(r, y);
	}
	for (int x = x0; x <= x1; x++) {
		double h = denaOvalHalfWidth(cx, ry, rx, x);
		if (h < 0) continue;
		int t = (int)std::floor(cy - h + 0.5), b = (int)std::floor(cy + h + 0.5);
		if (t < y0) t = y0;
		if (b > y1) b = y1;
		_safeSetPixelFromPen(x, t);
		_safeSetPixelFromPen(x, b);
	}
}

void Graphics::ovalfill(int x0, int y0, int x1, int y1, uint8_t col) {
	color(col);
	applyCameraToPoint(&x0, &y0);
	applyCameraToPoint(&x1, &y1);
	sortCoordsForRect(&x0, &y0, &x1, &y1);
	double cx = (x0 + x1) / 2.0, cy = (y0 + y1) / 2.0;
	double rx = (x1 - x0) / 2.0, ry = (y1 - y0) / 2.0;
	for (int y = y0; y <= y1; y++) {
		double w = denaOvalHalfWidth(cy, rx, ry, y);
		if (w < 0) continue;
		int l = (int)std::floor(cx - w + 0.5), r = (int)std::floor(cx + w + 0.5);
		if (l < x0) l = x0;
		if (r > x1) r = x1;
		_private_h_line(l, r, y);
	}
}
