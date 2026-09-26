// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AccountAdapter extends TypeAdapter<Account> {
  @override
  final int typeId = 1;

  @override
  Account read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Account(
      id: fields[0] as int,
      name: fields[1] as String,
      keywords: fields[2] == null
          ? const <String>[]
          : (fields[2] as List).cast<String>(),
      type: fields[3] as AccountType? ?? AccountType.office,
    );
  }

  @override
  void write(BinaryWriter writer, Account obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.keywords)
      ..writeByte(3)
      ..write(obj.type);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class TransactionModelAdapter extends TypeAdapter<TransactionModel> {
  @override
  final int typeId = 2;

  @override
  TransactionModel read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return TransactionModel(
      id: fields[0] as int,
      accountId: fields[1] as int,
      beneficiary: fields[2] as String,
      amount: fields[3] as double,
      currency: fields[4] as String,
      notes: fields[5] as String,
      status: fields[6] as TransactionStatus,
      date: fields[7] as DateTime,
      receivedAt: fields[8] as DateTime?,
      cancelledAt: fields[9] as DateTime?,
      secondAmount: fields[10] as double?,
      secondCurrency: fields[11] as String?,
      companyMovementType: fields[12] as CompanyMovementType?,
    );
  }

  @override
  void write(BinaryWriter writer, TransactionModel obj) {
    writer
      ..writeByte(13)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.accountId)
      ..writeByte(2)
      ..write(obj.beneficiary)
      ..writeByte(3)
      ..write(obj.amount)
      ..writeByte(4)
      ..write(obj.currency)
      ..writeByte(5)
      ..write(obj.notes)
      ..writeByte(6)
      ..write(obj.status)
      ..writeByte(7)
      ..write(obj.date)
      ..writeByte(8)
      ..write(obj.receivedAt)
      ..writeByte(9)
      ..write(obj.cancelledAt)
      ..writeByte(10)
      ..write(obj.secondAmount)
      ..writeByte(11)
      ..write(obj.secondCurrency)
      ..writeByte(12)
      ..write(obj.companyMovementType);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransactionModelAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class SettingsAdapter extends TypeAdapter<Settings> {
  @override
  final int typeId = 3;

  @override
  Settings read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Settings(
      nameKeywords: (fields[0] as List).cast<String>(),
      amountKeywords: (fields[1] as List).cast<String>(),
      currencyMap: (fields[2] as Map).cast<String, String>(),
      ignoredWords: (fields[3] as List).cast<String>(),
      lineIgnoredWords: fields[4] == null
          ? const <String>[]
          : (fields[4] as List).cast<String>(),
      cancelKeywords: fields[5] == null
          ? const <String>['الغاء']
          : (fields[5] as List).cast<String>(),
      amountWordValues: fields[6] == null
          ? const <String, double>{}
          : (fields[6] as Map).map(
              (key, value) =>
                  MapEntry(key.toString(), (value as num).toDouble()),
            ),
      bubbleReadyNames: fields[7] == null
          ? const <String>[]
          : (fields[7] as List).cast<String>(),
      bubbleQuickActions: fields[8] == null
          ? const <BubbleQuickActionConfig>[]
          : (fields[8] as List).cast<BubbleQuickActionConfig>(),
      companyUserNames: fields[9] == null
          ? const <String>[]
          : (fields[9] as List).cast<String>(),
      forbiddenWords: fields[10] is List
          ? (fields[10] as List).map((e) => e.toString()).toList()
          : const <String>[],
      forbiddenPhrases: fields[11] is List
          ? (fields[11] as List).map((e) => e.toString()).toList()
          : const <String>[],
      bubbleUiPrefs: fields[12] is Map
          ? (fields[12] as Map).map(
              (key, value) => MapEntry(key.toString(), value),
            )
          : const <String, dynamic>{},
      editKeywords: fields[13] is List
          ? (fields[13] as List).map((e) => e.toString()).toList()
          : const <String>['تعديل'],
    );
  }

  @override
  void write(BinaryWriter writer, Settings obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.nameKeywords)
      ..writeByte(1)
      ..write(obj.amountKeywords)
      ..writeByte(2)
      ..write(obj.currencyMap)
      ..writeByte(3)
      ..write(obj.ignoredWords)
      ..writeByte(4)
      ..write(obj.lineIgnoredWords)
      ..writeByte(5)
      ..write(obj.cancelKeywords)
      ..writeByte(6)
      ..write(obj.amountWordValues)
      ..writeByte(7)
      ..write(obj.bubbleReadyNames)
      ..writeByte(8)
      ..write(obj.bubbleQuickActions)
      ..writeByte(9)
      ..write(obj.companyUserNames)
      ..writeByte(10)
      ..write(obj.forbiddenWords)
      ..writeByte(11)
      ..write(obj.forbiddenPhrases)
      ..writeByte(12)
      ..write(obj.bubbleUiPrefs)
      ..writeByte(13)
      ..write(obj.editKeywords);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class BubbleQuickActionConfigAdapter
    extends TypeAdapter<BubbleQuickActionConfig> {
  @override
  final int typeId = 5;

  @override
  BubbleQuickActionConfig read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return BubbleQuickActionConfig(
      id: fields[0] == null
          ? DateTime.now().millisecondsSinceEpoch
          : (fields[0] as num).toInt(),
      label: fields[1]?.toString() ?? '',
      iconKey: fields[2]?.toString() ?? 'bolt',
      actionType: fields[3]?.toString() ?? 'clearStage',
      value: fields[4]?.toString() ?? '',
      iconAbove: fields[5] == true,
    );
  }

  @override
  void write(BinaryWriter writer, BubbleQuickActionConfig obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.label)
      ..writeByte(2)
      ..write(obj.iconKey)
      ..writeByte(3)
      ..write(obj.actionType)
      ..writeByte(4)
      ..write(obj.value)
      ..writeByte(5)
      ..write(obj.iconAbove);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BubbleQuickActionConfigAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class ParsedTextAdapter extends TypeAdapter<ParsedText> {
  @override
  final int typeId = 4;

  @override
  ParsedText read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ParsedText(
      id: fields[0] as int,
      title: fields[1] as String,
      originalText: fields[2] as String,
      selectedLines: (fields[3] as List).cast<String>(),
      finalLines: (fields[4] as List).cast<String>(),
      createdAt: fields[5] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, ParsedText obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.originalText)
      ..writeByte(3)
      ..write(obj.selectedLines)
      ..writeByte(4)
      ..write(obj.finalLines)
      ..writeByte(5)
      ..write(obj.createdAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParsedTextAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class TransactionStatusAdapter extends TypeAdapter<TransactionStatus> {
  @override
  final int typeId = 0;

  @override
  TransactionStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return TransactionStatus.added;
      case 1:
        return TransactionStatus.received;
      case 2:
        return TransactionStatus.cancelled;
      default:
        return TransactionStatus.added;
    }
  }

  @override
  void write(BinaryWriter writer, TransactionStatus obj) {
    switch (obj) {
      case TransactionStatus.added:
        writer.writeByte(0);
        break;
      case TransactionStatus.received:
        writer.writeByte(1);
        break;
      case TransactionStatus.cancelled:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransactionStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AccountTypeAdapter extends TypeAdapter<AccountType> {
  @override
  final int typeId = 6;

  @override
  AccountType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 1:
        return AccountType.company;
      case 0:
      default:
        return AccountType.office;
    }
  }

  @override
  void write(BinaryWriter writer, AccountType obj) =>
      writer.writeByte(obj.index);

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class CompanyMovementTypeAdapter extends TypeAdapter<CompanyMovementType> {
  @override
  final int typeId = 7;

  @override
  CompanyMovementType read(BinaryReader reader) {
    final index = reader.readByte();
    return CompanyMovementType.values[index.clamp(
      0,
      CompanyMovementType.values.length - 1,
    )];
  }

  @override
  void write(BinaryWriter writer, CompanyMovementType obj) =>
      writer.writeByte(obj.index);

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompanyMovementTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
