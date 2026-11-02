/* The SVG loader of libvips with resvg (native/vips_resvg), for the part
 * svg of vix (VIX_PARTS). It has the names and the arguments of the
 * loader of librsvg (svgload.c): svgload, svgload_buffer and
 * svgload_source. scripts/libvips.sh adds this file to libvips 8.18.7.
 *
 * The differences from svgload.c:
 *   - The loader draws the whole image into memory in one call, not in
 *     tiles.
 *   - The output is 8 bits for each band. high_bitdepth gives a warning.
 *   - The SVG gets only the images of data: URLs, and no file.
 *
 * This file is part of libvips and has its license, the LGPL 2.1 or
 * later. */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif /*HAVE_CONFIG_H*/
#include <glib/gi18n-lib.h>

#include <string.h>

#include <vips/vips.h>
#include <vips/internal.h>

#include <zlib.h>

/* The <svg tag must be in this count of bytes from the start of the file,
 * as in svgload.c. */
#define SVG_HEADER_SIZE (1000)

/* The request of native/vips_resvg/src/lib.rs. */
typedef struct _VipsResvg {
	int op;
	const unsigned char *svg;
	size_t len;
	double dpi;
	double scale;
	const char *stylesheet;
	guint32 width;
	guint32 height;
	unsigned char *pixels;
	char error[256];
} VipsResvg;

extern int vips_resvg(VipsResvg *request);

typedef struct _VipsForeignLoadSvg {
	VipsForeignLoad parent_object;

	double dpi;
	double scale;
	gboolean unlimited;
	gboolean high_bitdepth;
	const char *stylesheet;

	/* The bytes of the SVG, from the subclass.
	 */
	VipsBlob *data;

	/* The size from the header.
	 */
	guint32 width;
	guint32 height;
} VipsForeignLoadSvg;

typedef VipsForeignLoadClass VipsForeignLoadSvgClass;

G_DEFINE_ABSTRACT_TYPE(VipsForeignLoadSvg, vips_foreign_load_svg,
	VIPS_TYPE_FOREIGN_LOAD);

/* Find "<svg" in any case in the first bytes, after the inflate of SVGZ
 * data.
 */
static gboolean
vips_foreign_load_svg_is_a(const void *buf, size_t len)
{
	const unsigned char *str = buf;
	unsigned char obuf[SVG_HEADER_SIZE];
	size_t i;

	if (len >= 18 &&
		str[0] == 0x1f &&
		str[1] == 0x8b) {
		z_stream zs;
		int err;

		memset(&zs, 0, sizeof(zs));
		zs.next_in = (unsigned char *) str;
		zs.avail_in = len;
		if (inflateInit2(&zs, 15 | 32) != Z_OK)
			return FALSE;
		zs.next_out = obuf;
		zs.avail_out = sizeof(obuf);
		do {
			err = inflate(&zs, Z_NO_FLUSH);
		} while (err == Z_OK &&
			zs.avail_out > 0 &&
			zs.avail_in > 0);
		len = sizeof(obuf) - zs.avail_out;
		inflateEnd(&zs);
		if (err != Z_OK &&
			err != Z_STREAM_END &&
			err != Z_BUF_ERROR)
			return FALSE;
		str = obuf;
	}

	len = VIPS_MIN(len, SVG_HEADER_SIZE);
	for (i = 0; i + 4 <= len; i++)
		if (g_ascii_strncasecmp((const char *) str + i, "<svg", 4) == 0)
			return TRUE;

	return FALSE;
}

static void
vips_foreign_load_svg_dispose(GObject *gobject)
{
	VipsForeignLoadSvg *svg = (VipsForeignLoadSvg *) gobject;

	if (svg->data) {
		vips_area_unref(VIPS_AREA(svg->data));
		svg->data = NULL;
	}

	G_OBJECT_CLASS(vips_foreign_load_svg_parent_class)->dispose(gobject);
}

static int
vips_foreign_load_svg_build(VipsObject *object)
{
	VipsForeignLoadSvg *svg = (VipsForeignLoadSvg *) object;

	if (svg->high_bitdepth) {
		g_warning("ignoring high_bitdepth");
		svg->high_bitdepth = FALSE;
	}

	return VIPS_OBJECT_CLASS(vips_foreign_load_svg_parent_class)
		->build(object);
}

static VipsForeignFlags
vips_foreign_load_svg_get_flags_filename(const char *filename)
{
	return 0;
}

static VipsForeignFlags
vips_foreign_load_svg_get_flags(VipsForeignLoad *load)
{
	return 0;
}

/* One call of resvg. op 0 gives the size, op 1 also draws into pixels.
 * The lengths of the SVG are those of a dpi of 72, as in librsvg, and the
 * whole image has the scale scale * dpi / 72.
 */
static int
vips_foreign_load_svg_call(VipsForeignLoadSvg *svg, int op,
	unsigned char *pixels)
{
	VipsObjectClass *class = VIPS_OBJECT_GET_CLASS(svg);
	VipsResvg request;
	size_t len;

	memset(&request, 0, sizeof(request));
	request.op = op;
	request.svg = vips_area_get_data(VIPS_AREA(svg->data), &len,
		NULL, NULL, NULL);
	request.len = len;
	request.dpi = 72.0;
	request.scale = svg->scale * svg->dpi / 72.0;
	request.stylesheet = svg->stylesheet;
	request.width = svg->width;
	request.height = svg->height;
	request.pixels = pixels;
	if (vips_resvg(&request)) {
		vips_error(class->nickname, "%s", request.error);
		return -1;
	}
	svg->width = request.width;
	svg->height = request.height;

	return 0;
}

static void
vips_foreign_load_svg_fields(VipsForeignLoadSvg *svg, VipsImage *out)
{
	double res = svg->dpi / 25.4;

	vips_image_init_fields(out, svg->width, svg->height, 4,
		VIPS_FORMAT_UCHAR, VIPS_CODING_NONE, VIPS_INTERPRETATION_sRGB,
		res, res);
}

/* The header of each subclass, after it set svg->data.
 */
static int
vips_foreign_load_svg_header(VipsForeignLoad *load)
{
	VipsForeignLoadSvg *svg = (VipsForeignLoadSvg *) load;

	if (vips_foreign_load_svg_call(svg, 0, NULL))
		return -1;
	vips_foreign_load_svg_fields(svg, load->out);
	if (vips_image_pipelinev(load->out, VIPS_DEMAND_STYLE_ANY, NULL))
		return -1;

	return 0;
}

static int
vips_foreign_load_svg_load(VipsForeignLoad *load)
{
	VipsForeignLoadSvg *svg = (VipsForeignLoadSvg *) load;
	VipsImage *t = vips_image_new_memory();

	vips_foreign_load_svg_fields(svg, t);
	if (vips_image_pipelinev(t, VIPS_DEMAND_STYLE_ANY, NULL) ||
		vips_image_write_prepare(t) ||
		vips_foreign_load_svg_call(svg, 1, VIPS_IMAGE_ADDR(t, 0, 0)) ||
		vips_image_write(t, load->real)) {
		g_object_unref(t);
		return -1;
	}
	g_object_unref(t);

	return 0;
}

static void
vips_foreign_load_svg_class_init(VipsForeignLoadSvgClass *class)
{
	GObjectClass *gobject_class = G_OBJECT_CLASS(class);
	VipsObjectClass *object_class = (VipsObjectClass *) class;
	VipsOperationClass *operation_class = VIPS_OPERATION_CLASS(class);
	VipsForeignClass *foreign_class = (VipsForeignClass *) class;
	VipsForeignLoadClass *load_class = (VipsForeignLoadClass *) class;

	gobject_class->dispose = vips_foreign_load_svg_dispose;
	gobject_class->set_property = vips_object_set_property;
	gobject_class->get_property = vips_object_get_property;

	object_class->nickname = "svgload_base";
	object_class->description = _("load SVG with resvg");
	object_class->build = vips_foreign_load_svg_build;

	operation_class->flags |= VIPS_OPERATION_UNTRUSTED;

	/* is_a() is not quick: a low priority, as in svgload.c.
	 */
	foreign_class->priority = -5;

	load_class->get_flags_filename =
		vips_foreign_load_svg_get_flags_filename;
	load_class->get_flags = vips_foreign_load_svg_get_flags;
	load_class->load = vips_foreign_load_svg_load;

	VIPS_ARG_DOUBLE(class, "dpi", 21,
		_("DPI"),
		_("Render at this DPI"),
		VIPS_ARGUMENT_OPTIONAL_INPUT,
		G_STRUCT_OFFSET(VipsForeignLoadSvg, dpi),
		0.001, 100000.0, 72.0);

	VIPS_ARG_DOUBLE(class, "scale", 22,
		_("Scale"),
		_("Scale output by this factor"),
		VIPS_ARGUMENT_OPTIONAL_INPUT,
		G_STRUCT_OFFSET(VipsForeignLoadSvg, scale),
		0.0, 100000.0, 1.0);

	VIPS_ARG_BOOL(class, "unlimited", 23,
		_("Unlimited"),
		_("Allow SVG of any size"),
		VIPS_ARGUMENT_OPTIONAL_INPUT,
		G_STRUCT_OFFSET(VipsForeignLoadSvg, unlimited),
		FALSE);

	VIPS_ARG_STRING(class, "stylesheet", 24,
		_("Stylesheet"),
		_("Custom CSS"),
		VIPS_ARGUMENT_OPTIONAL_INPUT,
		G_STRUCT_OFFSET(VipsForeignLoadSvg, stylesheet),
		NULL);

	VIPS_ARG_BOOL(class, "high_bitdepth", 25,
		_("High bitdepth"),
		_("Enable scRGB 128-bit output (32-bit per channel)"),
		VIPS_ARGUMENT_OPTIONAL_INPUT,
		G_STRUCT_OFFSET(VipsForeignLoadSvg, high_bitdepth),
		FALSE);
}

static void
vips_foreign_load_svg_init(VipsForeignLoadSvg *svg)
{
	svg->dpi = 72.0;
	svg->scale = 1.0;
}

typedef struct _VipsForeignLoadSvgSource {
	VipsForeignLoadSvg parent_object;

	VipsSource *source;
} VipsForeignLoadSvgSource;

typedef VipsForeignLoadClass VipsForeignLoadSvgSourceClass;

G_DEFINE_TYPE(VipsForeignLoadSvgSource, vips_foreign_load_svg_source,
	vips_foreign_load_svg_get_type());

static gboolean
vips_foreign_load_svg_source_is_a_source(VipsSource *source)
{
	unsigned char *data;
	gint64 bytes_read;

	if ((bytes_read = vips_source_sniff_at_most(source,
			 &data, SVG_HEADER_SIZE)) <= 0)
		return FALSE;

	return vips_foreign_load_svg_is_a(data, bytes_read);
}

static int
vips_foreign_load_svg_source_header(VipsForeignLoad *load)
{
	VipsForeignLoadSvg *svg = (VipsForeignLoadSvg *) load;
	VipsForeignLoadSvgSource *source = (VipsForeignLoadSvgSource *) load;

	if (vips_source_rewind(source->source) ||
		!(svg->data = vips_source_map_blob(source->source)))
		return -1;

	return vips_foreign_load_svg_header(load);
}

static int
vips_foreign_load_svg_source_load(VipsForeignLoad *load)
{
	VipsForeignLoadSvgSource *source = (VipsForeignLoadSvgSource *) load;

	if (vips_foreign_load_svg_load(load) ||
		vips_source_decode(source->source))
		return -1;

	return 0;
}

static void
vips_foreign_load_svg_source_class_init(VipsForeignLoadSvgSourceClass *class)
{
	GObjectClass *gobject_class = G_OBJECT_CLASS(class);
	VipsObjectClass *object_class = (VipsObjectClass *) class;
	VipsOperationClass *operation_class = VIPS_OPERATION_CLASS(class);
	VipsForeignLoadClass *load_class = (VipsForeignLoadClass *) class;

	gobject_class->set_property = vips_object_set_property;
	gobject_class->get_property = vips_object_get_property;

	object_class->nickname = "svgload_source";
	object_class->description = _("load svg from source");

	operation_class->flags |= VIPS_OPERATION_NOCACHE;

	load_class->is_a_source = vips_foreign_load_svg_source_is_a_source;
	load_class->header = vips_foreign_load_svg_source_header;
	load_class->load = vips_foreign_load_svg_source_load;

	VIPS_ARG_OBJECT(class, "source", 1,
		_("Source"),
		_("Source to load from"),
		VIPS_ARGUMENT_REQUIRED_INPUT,
		G_STRUCT_OFFSET(VipsForeignLoadSvgSource, source),
		VIPS_TYPE_SOURCE);
}

static void
vips_foreign_load_svg_source_init(VipsForeignLoadSvgSource *source)
{
}

typedef struct _VipsForeignLoadSvgFile {
	VipsForeignLoadSvg parent_object;

	char *filename;
} VipsForeignLoadSvgFile;

typedef VipsForeignLoadSvgClass VipsForeignLoadSvgFileClass;

G_DEFINE_TYPE(VipsForeignLoadSvgFile, vips_foreign_load_svg_file,
	vips_foreign_load_svg_get_type());

static gboolean
vips_foreign_load_svg_file_is_a(const char *filename)
{
	unsigned char buf[SVG_HEADER_SIZE];
	guint64 bytes;

	return (bytes = vips__get_bytes(filename, buf,
				SVG_HEADER_SIZE)) > 0 &&
		vips_foreign_load_svg_is_a(buf, bytes);
}

static int
vips_foreign_load_svg_file_header(VipsForeignLoad *load)
{
	VipsForeignLoadSvg *svg = (VipsForeignLoadSvg *) load;
	VipsForeignLoadSvgFile *file = (VipsForeignLoadSvgFile *) load;
	VipsSource *source;

	if (!(source = vips_source_new_from_file(file->filename)))
		return -1;
	svg->data = vips_source_map_blob(source);
	g_object_unref(source);
	if (!svg->data)
		return -1;

	VIPS_SETSTR(load->out->filename, file->filename);

	return vips_foreign_load_svg_header(load);
}

static const char *vips_foreign_svg_suffs[] = {
	".svg",
	".svgz",
	".svg.gz",
	NULL
};

static void
vips_foreign_load_svg_file_class_init(VipsForeignLoadSvgFileClass *class)
{
	GObjectClass *gobject_class = G_OBJECT_CLASS(class);
	VipsObjectClass *object_class = (VipsObjectClass *) class;
	VipsForeignClass *foreign_class = (VipsForeignClass *) class;
	VipsForeignLoadClass *load_class = (VipsForeignLoadClass *) class;

	gobject_class->set_property = vips_object_set_property;
	gobject_class->get_property = vips_object_get_property;

	object_class->nickname = "svgload";

	foreign_class->suffs = vips_foreign_svg_suffs;

	load_class->is_a = vips_foreign_load_svg_file_is_a;
	load_class->header = vips_foreign_load_svg_file_header;

	VIPS_ARG_STRING(class, "filename", 1,
		_("Filename"),
		_("Filename to load from"),
		VIPS_ARGUMENT_REQUIRED_INPUT,
		G_STRUCT_OFFSET(VipsForeignLoadSvgFile, filename),
		NULL);
}

static void
vips_foreign_load_svg_file_init(VipsForeignLoadSvgFile *file)
{
}

typedef struct _VipsForeignLoadSvgBuffer {
	VipsForeignLoadSvg parent_object;

	VipsArea *buf;
} VipsForeignLoadSvgBuffer;

typedef VipsForeignLoadSvgClass VipsForeignLoadSvgBufferClass;

G_DEFINE_TYPE(VipsForeignLoadSvgBuffer, vips_foreign_load_svg_buffer,
	vips_foreign_load_svg_get_type());

static int
vips_foreign_load_svg_buffer_header(VipsForeignLoad *load)
{
	VipsForeignLoadSvg *svg = (VipsForeignLoadSvg *) load;
	VipsForeignLoadSvgBuffer *buffer = (VipsForeignLoadSvgBuffer *) load;

	vips_area_copy(buffer->buf);
	svg->data = (VipsBlob *) buffer->buf;

	return vips_foreign_load_svg_header(load);
}

static void
vips_foreign_load_svg_buffer_class_init(
	VipsForeignLoadSvgBufferClass *class)
{
	GObjectClass *gobject_class = G_OBJECT_CLASS(class);
	VipsObjectClass *object_class = (VipsObjectClass *) class;
	VipsForeignLoadClass *load_class = (VipsForeignLoadClass *) class;

	gobject_class->set_property = vips_object_set_property;
	gobject_class->get_property = vips_object_get_property;

	object_class->nickname = "svgload_buffer";

	load_class->is_a_buffer = vips_foreign_load_svg_is_a;
	load_class->header = vips_foreign_load_svg_buffer_header;

	VIPS_ARG_BOXED(class, "buffer", 1,
		_("Buffer"),
		_("Buffer to load from"),
		VIPS_ARGUMENT_REQUIRED_INPUT,
		G_STRUCT_OFFSET(VipsForeignLoadSvgBuffer, buf),
		VIPS_TYPE_BLOB);
}

static void
vips_foreign_load_svg_buffer_init(VipsForeignLoadSvgBuffer *buffer)
{
}
