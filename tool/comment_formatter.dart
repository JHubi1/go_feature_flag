import 'dart:io';

final lineLengthLimit = 80;
final commentRegex = RegExp(
  r"^([ \t]*)///.*(?:\r?\n[ \t]*///.*)*",
  multiLine: true,
);

void main(List<String> args) async {
  Directory.current = Platform.script.resolve("../lib").toFilePath();
  final baseDepth = Directory.current.path.split(Platform.pathSeparator).length;
  await for (final file in Directory.current.list(recursive: true)) {
    if (file is File && file.path.endsWith('.dart')) {
      final contents = await file.readAsString();
      final newContents = contents.replaceAllMapped(commentRegex, (match) {
        final indent = (match[1] ?? "").length;
        final content = (match[0] ?? "").replaceFirst(RegExp(r"\n$"), "");

        final sourceLines = content
            .split(r"///")
            .skip(1)
            .map((e) => e.replaceFirst(RegExp(r"///"), "").trim())
            .toList();
        final paragraphs = () {
          final buffer = <String>[];
          final paragraphs = <String>[];

          void flushBuffer() {
            if (buffer.isEmpty) return;
            final joined = buffer.join(" ");
            paragraphs.add(joined);
            buffer.clear();
          }

          while (sourceLines.isNotEmpty) {
            final sourceLine = sourceLines.removeAt(0);
            if (sourceLine == "") {
              flushBuffer();
            } else {
              buffer.add(sourceLine);
            }
          }
          flushBuffer();
          return paragraphs;
        }();

        final lines = paragraphs
            .map((p) {
              final textLineLength = lineLengthLimit - 4 - indent;
              final lines = <String>[];
              for (final word in p.split(" ")) {
                if (lines.isEmpty) {
                  lines.add(word);
                } else {
                  final lastLine = lines.last;
                  if ((lastLine.length + 1 + word.length) <= textLineLength) {
                    lines[lines.length - 1] = "$lastLine $word";
                  } else {
                    lines.add(word);
                  }
                }
              }
              return lines;
            })
            .reduce((a, b) => [...a, "", ...b]);
        return lines
            .map((line) {
              final l = line.trim();
              return "${" " * indent}///${l.isNotEmpty ? " " : ""}$l";
            })
            .join("\n");
      });
      if (newContents != contents) {
        await file.writeAsString(newContents);
        print(
          "File reformatted: "
          "${file.path.split(Platform.pathSeparator).skip(baseDepth).join("/")}",
        );
      }
    }
  }
}
