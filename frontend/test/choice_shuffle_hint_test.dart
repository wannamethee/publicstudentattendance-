// Same cases as scratch/exam_shuffle_test.py: the editor's hint must agree with what the server does.
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/widgets/choice_shuffle_hint.dart';

void main() {
  test('plain choices are all shuffled', () {
    expect(choiceShuffleKind(['3', '4', '5', '6']), isNull);
    expect(choiceShuffleKind(['ก', 'ข', 'ค']), isNull); // single consonants are plain answers
    expect(choiceShuffleKind(['10', '20', '30'], labels: 'number'), isNull);
  });

  test('"ถูกทุกข้อ" / "ไม่มีข้อใดถูก" / all of the above stay last', () {
    expect(choiceShuffleKind(['เท่ากับ 3', 'เท่ากับ 4', 'เท่ากับ 5', 'ถูกทุกข้อ']), 'tail');
    expect(choiceShuffleKind(['a1', 'a2', 'ถูกทั้งหมด', 'ไม่มีข้อใดถูก']), 'tail');
    expect(choiceShuffleKind(['x', 'y', 'Both of the above']), 'tail');
    expect(choiceShuffleKind(['x', 'y', 'All of the above', 'None of the above']), 'tail');
  });

  test('a choice that names other choices keeps the whole order', () {
    expect(choiceShuffleKind(['1', '2', 'ข้อ ก และ ข ถูก', 'ไม่มีข้อใดถูก']), 'fixed');
    expect(choiceShuffleKind(['x', 'y', 'ก และ ค', 'z']), 'fixed');
    expect(choiceShuffleKind(['p', 'q', 'ข้อ 1 และ 2 ถูก']), 'fixed');
    expect(choiceShuffleKind(['p', 'ตัวเลือก ข ถูก', 'q']), 'fixed');
    expect(choiceShuffleKind(['x', 'A and B', 'y']), 'fixed');
    expect(choiceShuffleKind(['x', 'a and b', 'y'], labels: 'latin'), 'fixed');
    expect(choiceShuffleKind(['x', '1 and 2', 'y'], labels: 'number'), 'fixed');
    expect(choiceShuffleKind(['ถูกทุกข้อ', 'ไม่มีข้อใดถูก']), 'fixed'); // every choice is positional
  });

  test('look-alikes are not mistaken', () {
    expect(choiceShuffleKind(['ไม่มีข้อมูล', 'มีข้อมูล', 'ข้อกำหนด']), isNull);
    expect(choiceShuffleKind(['ข้อกล่าวหา', 'คำพิพากษา', 'พยาน']), isNull);
    expect(choiceShuffleKind(['a and an', 'an and a', 'the'], labels: 'latin'), isNull);
  });

  test('blank choices are ignored and a hint exists only when something is special', () {
    expect(choiceShuffleKind(['', '3', '', '4']), isNull);
    expect(choiceShuffleKind(['3']), isNull);
    expect(choiceShuffleHint(null), isNull);
    expect(choiceShuffleHint('fixed'), isNotNull);
    expect(choiceShuffleHint('tail'), isNotNull);
  });
}
