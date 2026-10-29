// SPDX-License-Identifier: GPL-2.0-or-later
#include "job.h"
#include <cerrno>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr int width = 4825;
constexpr int height = 6817;
constexpr int row_bytes = (width + 7) / 8;
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
    throw std::runtime_error("Expected an A4 600 dpi raster (4825 x 6817)");
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
  if ((line.back() & 0x7f) != 0)
    throw std::runtime_error("Raster padding bits must be white");
  ++rows_read;
  return true;
}
}

int main(int argc, char **argv) {
  if (argc < 4) {
    std::cerr << "Usage: brother-encoder output.prn copies page.pbm ...\n";
    return 2;
  }
  FILE *output = nullptr;
  try {
    char *end = nullptr;
    errno = 0;
    const long copies = std::strtol(argv[2], &end, 10);
    if (errno || end == argv[2] || *end || copies < 1 || copies > 99)
      throw std::runtime_error("Copies must be between 1 and 99");
    for (int i = 3; i < argc; ++i) {
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
      params.resolution = 600;
      params.sourcetray = "AUTO";
      params.mediatype = "PLAIN";
      params.papersize = "A4";
      for (long copy = 0; copy < copies; ++copy) {
        for (int i = 3; i < argc; ++i) {
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
