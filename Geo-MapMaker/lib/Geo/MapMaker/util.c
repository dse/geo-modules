#include <math.h>
#include <string.h>
#include <stdlib.h>

#define IS_ARRAY_REF(sv) (SvOK(sv) && SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVAV)

int move_line_away_debug = 0;

#define DEBUGC(c)       (move_line_away_debug && putc(c, stderr))
#define DEBUGF(args...) (move_line_away_debug && fprintf(stderr, args))

inline double pyth (double x0, double y0, double x1, double y1) {
	double dx = x1 - x0;
	double dy = y1 - y0;
	return sqrt(dx * dx + dy * dy);
}

void av_to_arrays (AV* points,
		   double** xp,
		   double** yp,
		   int* npointsp);

void move_point_away (double* xp,
		      double* yp,
		      double minimum_distance,
		      double general_direction,
		      double* xx,
		      double* yy,
		      int npoints);

void segment_voodoo (double cx, double cy,
		     double ax, double ay,
		     double bx, double by,
		     double *rlp,
		     double *pxp,
		     double *pyp,
		     double *slp,
		     double *dlp);

void move_line_away (SV* arg_north,
		     SV* arg_south,
		     SV* arg_east,
		     SV* arg_west,
		     SV* arg_minimum_distance,
		     SV* arg_general_direction,
		     SV* arg_points_b,
		     SV* arg_points_a) {
	
	if (getenv("MOVE_LINE_AWAY_DEBUG")) {
		move_line_away_debug = atoi(getenv("MOVE_LINE_AWAY_DEBUG"));
	}
	else {
		move_line_away_debug = 0;
	}

	int i;

	int check_north = SvOK(arg_north);
	int check_south = SvOK(arg_south);
	int check_east  = SvOK(arg_east);
	int check_west  = SvOK(arg_west);

	double north = check_north ? SvNV(arg_north) : 0;
	double south = check_south ? SvNV(arg_south) : 0;
	double east  = check_east  ? SvNV(arg_east)  : 0;
	double west  = check_west  ? SvNV(arg_west)  : 0;

	if (check_south && check_north && south < north) {
		double temp = south;
		south = north;
		north = temp;
	}
	if (check_east && check_west && east < west) {
		double temp = east;
		east = west;
		west = temp;
	}

	double minimum_distance = SvOK(arg_minimum_distance) ? SvNV(arg_minimum_distance) : 1.0;

	double general_direction;
	if (SvOK(arg_general_direction)) {
		char* general_direction_s = SvPV(arg_general_direction, PL_na);
		if      (!strcmp(general_direction_s, "north")     || !strcmp(general_direction_s, "n") ) { general_direction = atan2(-1,  0); }
		else if (!strcmp(general_direction_s, "south")     || !strcmp(general_direction_s, "s") ) { general_direction = atan2( 1,  0); }
		else if (!strcmp(general_direction_s, "east")      || !strcmp(general_direction_s, "e") ) { general_direction = atan2( 0,  1); }
		else if (!strcmp(general_direction_s, "west")      || !strcmp(general_direction_s, "w") ) { general_direction = atan2( 0, -1); }
		else if (!strcmp(general_direction_s, "northeast") || !strcmp(general_direction_s, "ne")) { general_direction = atan2(-1,  1); }
		else if (!strcmp(general_direction_s, "southeast") || !strcmp(general_direction_s, "se")) { general_direction = atan2( 1,  1); }
		else if (!strcmp(general_direction_s, "northwest") || !strcmp(general_direction_s, "nw")) { general_direction = atan2(-1, -1); }
		else if (!strcmp(general_direction_s, "southwest") || !strcmp(general_direction_s, "sw")) { general_direction = atan2( 1, -1); }
		else if (!strcmp(general_direction_s, "ese")) { general_direction = atan2(1, 1) * 0.5; }
		else if (!strcmp(general_direction_s, "sse")) { general_direction = atan2(1, 1) * 1.5; }
		else if (!strcmp(general_direction_s, "ssw")) { general_direction = atan2(1, 1) * 2.5; }
		else if (!strcmp(general_direction_s, "wsw")) { general_direction = atan2(1, 1) * 3.5; }
		else if (!strcmp(general_direction_s, "wnw")) { general_direction = atan2(1, 1) * 4.5; }
		else if (!strcmp(general_direction_s, "nnw")) { general_direction = atan2(1, 1) * 5.5; }
		else if (!strcmp(general_direction_s, "nne")) { general_direction = atan2(1, 1) * 6.5; }
		else if (!strcmp(general_direction_s, "ene")) { general_direction = atan2(1, 1) * 7.5; }
		else { general_direction = SvNV(arg_general_direction); }
	}
	else {
		general_direction = 0; /* a reasonable default I suppose */
	}

	if (!IS_ARRAY_REF(arg_points_a)) return;
	if (!IS_ARRAY_REF(arg_points_b)) return;

	AV* points_a = (AV*)SvRV(arg_points_a);
	AV* points_b = (AV*)SvRV(arg_points_b);

	double* xx_a;
	double* yy_a;
	int npoints_a;
	av_to_arrays(points_a, &xx_a, &yy_a, &npoints_a);

	SV** pointp;
	SV* point;
	AV* xy;
	double x, y;

	for (i = 0; i <= av_len(points_b); i += 1) {
		pointp = av_fetch(points_b, i, 0);
		if (!pointp || !*pointp) continue;
		point = *pointp;
		if (!IS_ARRAY_REF(point)) continue;
		xy = (AV*)SvRV(point);
		if (av_len(xy) < 1) continue;
		x = SvNV(*(av_fetch(xy, 0, 0)));
		y = SvNV(*(av_fetch(xy, 1, 0)));
		if (check_north && y < north) continue;
		if (check_south && y > south) continue;
		if (check_east && x > east)  continue;
		if (check_west && x < west)  continue;
		move_point_away(&x, &y, minimum_distance, general_direction, xx_a, yy_a, npoints_a);
		av_store(xy, 0, newSVnv(x));
		av_store(xy, 1, newSVnv(y));
	}

	free(xx_a);
	free(yy_a);
}

typedef struct {
	double dp;
} point_info_t;

typedef struct {
	double rl;
	double px;
	double py;
	double sl;
	double dl;
	double ll;
	double l2;
	double dx;
	double dy;
	double theta;
} line_info_t;

void recalculate (double cx, double cy, double* xx, double* yy, int npoints, point_info_t* point_info, line_info_t* line_info) {
	int i;
	double ax, ay, bx, by;
	double dp, rl, px, py, sl, dl, ll, dx, dy, theta, l2;
	for (i = 0; i < npoints; i += 1) {
		point_info[i].dp = pyth(cx, cy, xx[i], yy[i]);
	}
	for (i = 0; i < (npoints - 1); i += 1) {
		ax = xx[i];
		ay = yy[i];
		bx = xx[i+1];
		by = yy[i+1];
		line_info[i].ll    = ll    = pyth(ax, ay, bx, by);
		line_info[i].l2    = l2    = ll * ll;
		line_info[i].dx    = dx    = bx - ax;
		line_info[i].dy    = dy    = by - ay;
		line_info[i].theta = theta = atan2(dy, dx);
		line_info[i].rl    = rl    = ((cx - ax) * (bx - ax) + (cy - ay) * (by - ay)) / l2;
		line_info[i].px    = px    = ax + rl * (bx - ax);
		line_info[i].py    = py    = ay + rl * (by - ay);
		line_info[i].sl    = sl    = ((ay - cy) * (bx - ax) - (ax - cx) * (by - ay)) / l2;
		line_info[i].dl    = dl    = fabs(sl) * ll;
	}
}

void move_point_away (double* xp,
		      double* yp,
		      double minimum_distance,
		      double general_direction,
		      double* xx,
		      double* yy,
		      int npoints) {

	double distance = minimum_distance;
	minimum_distance = distance + 0.001; /* fudge factor */

	if (npoints < 1) {
		return;
	}
	if (npoints == 1) {
		double theta = atan2(yy[0] - *yp, xx[0] - *xp);
		if (pyth(*xp, *yp, xx[0], yy[0]) < minimum_distance) {
			*xp = xx[0] + distance * cos(theta);
			*yp = yy[0] + distance * sin(theta);
		}
		return;
	}

	int i;
	point_info_t* point_info = (point_info_t *) malloc(sizeof(point_info_t) * npoints);
	line_info_t*  line_info  = (line_info_t *)  malloc(sizeof(line_info_t)  * npoints);
	recalculate(*xp, *yp, xx, yy, npoints, point_info, line_info);

	double adx;
	double ady;
	double atheta;
start_over:
	for (i = 0; i < (npoints - 2); i += 1) {
		if ((line_info[i].dl < minimum_distance &&
		     line_info[i+1].dl < minimum_distance &&
		     line_info[i].rl >= 0 &&
		     line_info[i].rl <= 1 &&
		     line_info[i+1].rl >= 0 && 
		     line_info[i+1].rl <= 1) || 
		    point_info[i+1].dp < minimum_distance) {
			adx = line_info[i].dx / line_info[i].ll + line_info[i+1].dx / line_info[i+1].ll;
			ady = line_info[i].dy / line_info[i].ll + line_info[i+1].dy / line_info[i+1].ll;
			atheta = atan2(ady, adx);
			if (sin(atheta - general_direction) < 0) {
				*xp = xx[i+1] - distance * sin(atheta);
				*yp = yy[i+1] + distance * cos(atheta);
			}
			else {
				*xp = xx[i+1] + distance * sin(atheta);
				*yp = yy[i+1] - distance * cos(atheta);
			}
			recalculate(*xp, *yp, xx, yy, npoints, point_info, line_info);
		}
	}
	for (i = 0; i < (npoints - 1); i += 1) {
		if (line_info[i].dl < minimum_distance && line_info[i].rl >= 0 && line_info[i].rl <= 1) {
			if (sin(line_info[i].theta - general_direction) < 0) {
				*xp = line_info[i].px - distance * sin(line_info[i].theta);
				*yp = line_info[i].py + distance * cos(line_info[i].theta);
			}
			else {
				*xp = line_info[i].px + distance * sin(line_info[i].theta);
				*yp = line_info[i].py - distance * cos(line_info[i].theta);
			}
			recalculate(*xp, *yp, xx, yy, npoints, point_info, line_info);
		}
	}
	if (point_info[0].dp < minimum_distance) {
		if (sin(line_info[0].theta - general_direction) < 0) {
			*xp = xx[0] - distance * sin(line_info[0].theta);
			*yp = yy[0] + distance * cos(line_info[0].theta);
		}
		else {
			*xp = xx[0] + distance * sin(line_info[0].theta);
			*yp = yy[0] - distance * cos(line_info[0].theta);
		}
		recalculate(*xp, *yp, xx, yy, npoints, point_info, line_info);
	}
	else if (point_info[npoints - 1].dp < minimum_distance) {
		if (sin(line_info[npoints - 2].theta - general_direction) < 0) {
			*xp = xx[npoints-1] - distance * sin(line_info[npoints-2].theta);
			*yp = yy[npoints-1] + distance * cos(line_info[npoints-2].theta);
		}
		else {
			*xp = xx[npoints-1] + distance * sin(line_info[npoints-2].theta);
			*yp = yy[npoints-1] - distance * cos(line_info[npoints-2].theta);
		}
		recalculate(*xp, *yp, xx, yy, npoints, point_info, line_info);
	}
	
	free(point_info);
	free(line_info);
}

void av_to_arrays (AV* points,
		   double** xp,
		   double** yp,
		   int* npointsp) {
	int prev_exists;
	int i;
	int j;
	double prev_x;
	double prev_y;
	double x;
	double y;

	*npointsp = 0;
	*xp = (double *)malloc(sizeof(double) * (av_len(points) + 1));
	*yp = (double *)malloc(sizeof(double) * (av_len(points) + 1));

	for (i = 0, j = 0; i <= av_len(points); i += 1) {
		SV** pointp = av_fetch(points, i, 0);
		if (!pointp || !*pointp) continue;
		SV* point = *pointp;
		if (!IS_ARRAY_REF(point)) continue;
		AV* xy = (AV*)SvRV(point);
		if (av_len(xy) < 1) continue;
		x = SvNV(*(av_fetch(xy, 0, 0)));
		y = SvNV(*(av_fetch(xy, 1, 0)));
		if (prev_exists && x == prev_x && y == prev_y) continue;
		(*xp)[j] = x;
		(*yp)[j] = y;
		j += 1;
		prev_x = x;
		prev_y = y;
		prev_exists = 1;
	}
	*npointsp = j;
}

void segment_voodoo (double cx, double cy,
		     double ax, double ay,
		     double bx, double by,
		     double *rlp,
		     double *pxp,
		     double *pyp,
		     double *slp,
		     double *dlp) {
	double l2 = (bx - ax) * (bx - ax) + (by - ay) * (by - ay);
	double ll  = sqrt(l2);
	double rl = ((cx - ax) * (bx - ax) + (cy - ay) * (by - ay)) / l2;
	double px = ax + rl * (bx - ax);
	double py = ay + rl * (by - ay);
	double sl = ((ay - cy) * (bx - ax) - (ax - cx) * (by - ay)) / l2;
	double dl = fabs(sl) * ll;

	*rlp = rl;
	*pxp = px;
	*pyp = py;
	*slp = sl;
	*dlp = dl;

	DEBUGF("cx=%7.2f;cy=%7.2f;ax=%7.2f;ay=%7.2f;bx=%7.2f;by=%7.2f;l2=%7.2f;ll=%7.2f;rl=%7.2f;px=%7.2f;py=%7.2f;sl=%7.2f;dl=%7.2f\n",
	       cx, cy, ax, ay, bx, by, l2, ll, rl, px, py, sl, dl);
}

/* Local Variables: */
/* c-file-style: "bsd" */
/* End: */
