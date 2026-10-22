-- ============================================================================
-- ASM Expense & Reimbursement Platform — Add Standard International Currencies & Exchange Rates
-- Migration: 20261022000016_add_international_currencies.sql
-- ============================================================================

INSERT INTO currencies (code, name, symbol, decimals, is_base, is_active) VALUES
('GBP', 'British Pound', '£', 2, false, true),
('INR', 'Indian Rupee', '₹', 2, false, true),
('SAR', 'Saudi Riyal', 'SAR', 2, false, true),
('QAR', 'Qatari Riyal', 'QAR', 2, false, true),
('OMR', 'Omani Rial', 'OMR', 2, false, true),
('BHD', 'Bahraini Dinar', 'BHD', 3, false, true),
('KWD', 'Kuwaiti Dinar', 'KWD', 3, false, true),
('SGD', 'Singapore Dollar', 'S$', 2, false, true),
('JPY', 'Japanese Yen', '¥', 0, false, true),
('CHF', 'Swiss Franc', 'CHF', 2, false, true),
('CAD', 'Canadian Dollar', 'CA$', 2, false, true),
('AUD', 'Australian Dollar', 'AU$', 2, false, true)
ON CONFLICT (code) DO UPDATE 
SET name = EXCLUDED.name, symbol = EXCLUDED.symbol, decimals = EXCLUDED.decimals, is_active = true;

-- Authoritative fallback/initial exchange rates to AED
INSERT INTO exchange_rates (from_currency, to_currency, rate, effective_date, source) VALUES
('GBP', 'AED', 4.755000, '2026-01-01', 'Central Bank of the UAE Fix'),
('INR', 'AED', 0.044000, '2026-01-01', 'Central Bank of the UAE Fix'),
('SAR', 'AED', 0.979000, '2026-01-01', 'Central Bank of the UAE Fix'),
('QAR', 'AED', 1.008000, '2026-01-01', 'Central Bank of the UAE Fix'),
('OMR', 'AED', 9.550000, '2026-01-01', 'Central Bank of the UAE Fix'),
('BHD', 'AED', 9.740000, '2026-01-01', 'Central Bank of the UAE Fix'),
('KWD', 'AED', 11.950000, '2026-01-01', 'Central Bank of the UAE Fix'),
('SGD', 'AED', 2.820000, '2026-01-01', 'Central Bank of the UAE Fix'),
('JPY', 'AED', 0.024500, '2026-01-01', 'Central Bank of the UAE Fix'),
('CHF', 'AED', 4.150000, '2026-01-01', 'Central Bank of the UAE Fix'),
('CAD', 'AED', 2.680000, '2026-01-01', 'Central Bank of the UAE Fix'),
('AUD', 'AED', 2.410000, '2026-01-01', 'Central Bank of the UAE Fix')
ON CONFLICT (from_currency, to_currency, effective_date) DO UPDATE 
SET rate = EXCLUDED.rate;
