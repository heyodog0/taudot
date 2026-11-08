/* Taudot's drawing runtime: an included PDF is only a file to point a figure op at (see fitz.h, fz_figure).
 * Copyright (c) 2026 the Taudot authors. MIT License (rt/LICENSE). */
#ifndef TAUDOT_RT_PDF_H
#define TAUDOT_RT_PDF_H
#include "fitz.h"

typedef struct pdf_document
{
  char *path;
  int pages;
} pdf_document;

/* Checks the file is a PDF Core Graphics can open (the stream must come from fz_open_file). */
pdf_document *pdf_open_document_with_stream(fz_context *ctx, fz_stream *stm);
void pdf_drop_document(fz_context *ctx, pdf_document *doc);

#endif
