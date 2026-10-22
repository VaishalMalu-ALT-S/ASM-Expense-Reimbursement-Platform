class CurrencyItem {
  final String code;
  final String name;
  final String symbol;
  final int decimals;

  const CurrencyItem({
    required this.code,
    required this.name,
    required this.symbol,
    this.decimals = 2,
  });

  factory CurrencyItem.fromJson(Map<String, dynamic> json) {
    return CurrencyItem(
      code: (json['code'] as String).trim().toUpperCase(),
      name: (json['name'] as String? ?? json['code'] as String).trim(),
      symbol: (json['symbol'] as String? ?? json['code'] as String).trim(),
      decimals: (json['decimals'] as num?)?.toInt() ?? 2,
    );
  }

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'symbol': symbol,
    'decimals': decimals,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CurrencyItem && runtimeType == other.runtimeType && code == other.code;

  @override
  int get hashCode => code.hashCode;

  String get displayName => '$code - $name ($symbol)';
}
