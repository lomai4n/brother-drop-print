// SPDX-License-Identifier: GPL-2.0-or-later
#include "job.h"
#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
// Paper sizes in points with the upstream brlaser margins (left 8, bottom 8, right 8, top 16).
// Must match PageSetup in Sources/Core.swift.
struct paper_size { const char *name; double width, height; };
constexpr paper_size papers[] = {
  {"A4", 595, 842}, {"A5", 420, 595}, {"A6", 297, 420}, {"B5", 499, 709},
  {"LETTER", 612, 792}, {"LEGAL", 612, 1008}, {"EXECUTIVE", 522, 756},
};
const char *const media_types[] = {"PLAIN", "THIN", "THICK", "THICKER", "BOND", "ENV"};

int width = 0;
int height = 0;
int row_bytes = 0;
uint8_t padding_mask = 0;
std::ifstream *current_page = nullptr;
int rows_read = 0;

std::streamoff read_header(std::ifstream &input) {
  std::string magic, dimensions, extra;
  int w = 0, h = 0;
  if (!std::getline(input, magic) || !std::getline(input, dimensions))
    throw std::runtime_error("Missing raster header");
  std::istringstream values(dimensions);
  if (magic != "P4" || !(values >> w >> h) || (values >> extra) ||
      w != width || h != height)
    throw std::runtime_error("Raster size does not match the selected paper and resolution");
  const auto offset = input.tellg();
  input.seekg(0, std::ios::end);
  if (input.tellg() - offset != std::streamoff(row_bytes) * height)
    throw std::runtime_error("Raster data is truncated or has extra bytes");
  input.seekg(offset);
  return offset;
}

bool read_line(std::vector<uint8_t> &line) {
  if (!current_page->read(reinterpret_cast<char *>(line.data()), row_bytes))
    return false;
  if ((line.back() & padding_mask) != 0)
    throw std::runtime_error("Raster padding bits must be white");
  ++rows_read;
  return true;
}
}

int main(int argc, char **argv) {
  if (argc < 9) {
    std::cerr << "Usage: brother-encoder output.prn copies paper dpi economode density media page.pbm ...\n";
    return 2;
  }
  FILE *output = nullptr;
  try {
    auto integer = [](const char *text, long low, long high, const char *message) {
      char *end = nullptr;
      errno = 0;
      const long value = std::strtol(text, &end, 10);
      if (errno || end == text || *end || value < low || value > high)
        throw std::runtime_error(message);
      return value;
    };
    const long copies = integer(argv[2], 1, 99, "Copies must be between 1 and 99");
    const paper_size *paper = nullptr;
    for (const auto &candidate : papers)
      if (std::strcmp(candidate.name, argv[3]) == 0) paper = &candidate;
    if (!paper)
      throw std::runtime_error("Unsupported paper size");
    const long dpi = integer(argv[4], 300, 600, "Resolution must be 300 or 600");
    if (dpi != 300 && dpi != 600)
      throw std::runtime_error("Resolution must be 300 or 600");
    const long economode = integer(argv[5], 0, 1, "Toner save must be 0 or 1");
    const long density = integer(argv[6], -6, 6, "Density must be between -6 and 6");
    bool known_media = false;
    for (const char *media : media_types) known_media |= std::strcmp(media, argv[7]) == 0;
    if (!known_media)
      throw std::runtime_error("Unsupported media type");
    width = static_cast<int>(std::lround((paper->width - 16) * dpi / 72));
    height = static_cast<int>(std::lround((paper->height - 24) * dpi / 72));
    row_bytes = (width + 7) / 8;
    padding_mask = width % 8 ? static_cast<uint8_t>(0xff >> (width % 8)) : 0;
    constexpr int first_page = 8;
    for (int i = first_page; i < argc; ++i) {
      std::ifstream page(argv[i], std::ios::binary);
      if (!page)
        throw std::runtime_error("Cannot open raster input");
      read_header(page);
    }
    output = std::fopen(argv[1], "wbx");
    if (!output)
      throw std::runtime_error("Cannot create output (it must not already exist)");
    {
      job printer_job(output, "Brother Drop Print");
      page_params params{};
      params.num_copies = 1;
      params.resolution = static_cast<int>(dpi);
      params.economode = economode == 1;
      params.density_adjust = static_cast<int>(density);
      params.sourcetray = "AUTO";
      params.mediatype = argv[7];
      params.papersize = paper->name;
      for (long copy = 0; copy < copies; ++copy) {
        for (int i = first_page; i < argc; ++i) {
          std::ifstream page(argv[i], std::ios::binary);
          read_header(page);
          current_page = &page;
          rows_read = 0;
          printer_job.encode_page(params, height, row_bytes, read_line);
          if (rows_read != height || page.bad())
            throw std::runtime_error("Not all raster rows were encoded");
          if (std::ferror(output))
            throw std::runtime_error("Writing print data failed");
        }
      }
    }
    const bool failed = std::ferror(output) != 0;
    const int close_result = std::fclose(output);
    output = nullptr;
    if (failed || close_result)
      throw std::runtime_error("Finishing print data failed");
    return 0;
  } catch (const std::exception &error) {
    if (output)
      std::fclose(output);
    std::cerr << error.what() << "\n";
    return 1;
  }
}
