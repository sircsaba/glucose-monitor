import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glucose_monitor/logic/pdf_text.dart';
import 'package:glucose_monitor/logic/recipe_parse.dart';
import 'package:glucose_monitor/logic/recipe_web.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  group('recipe from a web page', () {
    test('schema.org Recipe in a @graph, with sections and HTML entities', () {
      const html = '''<html><head><title>Banana muffins | My site</title>
<script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebPage","name":"x"},
{"@type":["Recipe"],"name":"Banana &amp; maple muffins","recipeYield":["12","12 muffins"],"prepTime":"PT15M","cookTime":"PT1H5M",
"recipeIngredient":["2 cups rice flour","3 ripe bananas, mashed","1/3 cup maple syrup","&frac12; tsp salt"],
"recipeInstructions":[{"@type":"HowToSection","name":"Batter","itemListElement":[{"@type":"HowToStep","text":"Heat the oven to 180&deg;C."},{"@type":"HowToStep","text":"Mix <b>everything</b>."}]},
{"@type":"HowToStep","text":"Bake 20 minutes."}]}]}</script></head><body></body></html>''';
      final r = recipeFromHtml(html)!;
      expect(r.title, 'Banana & maple muffins');
      expect(r.servings, 12);
      expect(r.ingredients, ['2 cups rice flour', '3 ripe bananas, mashed', '1/3 cup maple syrup', '½ tsp salt']);
      expect(r.steps, ['Batter:', 'Heat the oven to 180°C.', 'Mix everything.', 'Bake 20 minutes.']);
      expect(r.prepMinutes, 15);
      expect(r.cookMinutes, 65);
      // The recipe reader gets the same lines back.
      final p = splitRecipe(r.toText());
      expect(p.title, r.title);
      expect(p.ingredients.length, 4);
      expect(p.servings, 12);
    });

    test('instructions as one text, yield "Makes 8 pancakes"', () {
      const html = '''<script type="application/ld+json">[{"@type":"Recipe","name":"Pancakes","recipeYield":"Makes 8 pancakes",
"recipeIngredient":["1 cup flour","1 egg"],"recipeInstructions":"1. Mix.\\n2. Cook on a hot pan."}]</script>''';
      final r = recipeFromHtml(html)!;
      expect(r.servings, 8);
      expect(r.servingText, 'pancake');
      expect(r.steps, ['Mix.', 'Cook on a hot pan.']);
    });

    test('a page with only lists after headings', () {
      const html = '''<html><body><h1>Crêpes de Mémé</h1><p>Intro text</p>
<h2>Ingrédients</h2><ul><li>2 tasses de lait</li><li>1 tasse de farine de riz</li><li>2 oeufs</li></ul>
<h2>Préparation</h2><ol><li>Mélanger tous les ingrédients.</li><li>Cuire dans une poêle chaude.</li></ol></body></html>''';
      final r = recipeFromHtml(html)!;
      expect(r.title, 'Crêpes de Mémé');
      expect(r.ingredients, ['2 tasses de lait', '1 tasse de farine de riz', '2 oeufs']);
      expect(r.steps.length, 2);
    });

    test('no recipe on the page', () {
      expect(recipeFromHtml('<html><body><p>Hello</p></body></html>'), isNull);
    });

    // Real pages, fetched by the test job (RECIPE_PAGES): shows what is read.
    final dir = Platform.environment['RECIPE_PAGES'];
    if (dir != null && Directory(dir).existsSync()) {
      for (final f in Directory(dir).listSync().whereType<File>()) {
        test('real page ${f.uri.pathSegments.last}', () {
          final r = recipeFromHtml(f.readAsStringSync());
          // ignore: avoid_print
          print('${f.uri.pathSegments.last}: ${r == null ? 'NO RECIPE' : '"${r.title}", ${r.servings} servings, ${r.ingredients.length} ingredients, ${r.steps.length} steps; first: ${r.ingredients.firstOrNull}'}');
        });
      }
    }
  });

  group('recipe from a PDF', () {
    test('text of a PDF made by a program (compressed, standard font, accents)', () async {
      final doc = pw.Document();
      doc.addPage(pw.Page(
          pageFormat: PdfPageFormat.letter,
          build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text('Crêpes sans gluten', style: const pw.TextStyle(fontSize: 22)),
                pw.Text('Makes 8'),
                pw.SizedBox(height: 10),
                pw.Text('Ingredients'),
                pw.Text('2 cups milk'),
                pw.Text('1 cup rice flour'),
                pw.Text('2 eggs'),
                pw.Text('Directions'),
                pw.Text('1. Mix everything in a large bowl until smooth.'),
                pw.Text('2. Cook in a hot pan, 1 minute a side.'),
              ])));
      doc.addPage(pw.Page(build: (_) => pw.Text('Page two: serve with maple syrup.')));
      final bytes = await doc.save();
      final pages = pdfPageTexts(bytes);
      expect(pages.length, 2);
      final text = pdfText(bytes);
      // ignore: avoid_print
      print('PDF TEXT >>>${text.replaceAll('\n', ' | ')}<<<');
      expect(pdfLooksScanned(text), isFalse);
      final lines = text.split('\n');
      expect(lines, contains('Crêpes sans gluten'));
      expect(lines, contains('2 cups milk'));
      expect(lines, contains('1. Mix everything in a large bowl until smooth.'));
      expect(pages[1], contains('maple syrup'));
      final r = splitRecipe(text);
      expect(r.title, 'Crêpes sans gluten');
      expect(r.ingredients, ['2 cups milk', '1 cup rice flour', '2 eggs']);
      expect(r.servings, 8);
    });

    test('a PDF with only a picture is "scanned"', () async {
      final doc = pw.Document();
      final img = pw.MemoryImage(_png);
      doc.addPage(pw.Page(build: (_) => pw.Image(img)));
      final text = pdfText(await doc.save());
      expect(pdfLooksScanned(text), isTrue);
    });

    test('not a PDF', () {
      expect(pdfText(Uint8List.fromList(utf8.encode('hello'))), '');
    });
  });
}

// A 1x1 PNG.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');
