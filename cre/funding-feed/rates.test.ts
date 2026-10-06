import { describe, expect, it } from 'bun:test'
import { parse, perSecondWad } from './rates'

describe('per-second conversion', () => {
	// Without this, the CRE path and validation/relayer.py could post different values for the same venue reading:
	// relayer.py's tests pin 0.01% per 8 h to the same per-second rate as 0.00125% per 1 h (10.95% a year).
	it('matches relayer.py on its own test values', () => {
		expect(perSecondWad(0.0001, 8)).toBe(3472222222n)
		expect(perSecondWad(0.0000125, 1)).toBe(perSecondWad(0.0001, 8))
		expect(perSecondWad(-0.00000327, 8)).toBe(-113541667n) // negative rates keep their sign (shorts pay)
	})
})

describe('venue parsing', () => {
	// Without this, a venue's response shape (or its funding interval) could be misread, and the feed would take a
	// median over wrong inputs without anyone noticing. Fixtures are trimmed copies of live responses (2026-10-07).
	it('reads each venue\'s predicted rate and interval', () => {
		expect(parse.binance({ symbol: 'BTCUSDT', lastFundingRate: '0.00002210' })).toEqual({ rate: 0.0000221, intervalH: 8 })
		expect(parse.okx({ data: [{ fundingRate: '0.0000333463272422', fundingTime: '1791331200000', nextFundingTime: '1791360000000' }] }))
			.toEqual({ rate: 0.0000333463272422, intervalH: 8 })
		expect(parse.bybit({ result: { list: [{ fundingRate: '-0.00000327', fundingIntervalHour: '8' }] } })).toEqual({ rate: -0.00000327, intervalH: 8 })
		expect(parse.hyperliquid([['ETH', [['HlPerp', { fundingRate: '0.00001', fundingIntervalHours: 1 }]]],
			['BTC', [['BinPerp', { fundingRate: '0.0002', fundingIntervalHours: 8 }], ['HlPerp', { fundingRate: '0.0000125', nextFundingTime: 1, fundingIntervalHours: 1 }]]]]))
			.toEqual({ rate: 0.0000125, intervalH: 1 })
		expect(parse.bitget({ data: [{ symbol: 'BTCUSDT', fundingRate: '0.000014', fundingRateInterval: '8' }] })).toEqual({ rate: 0.000014, intervalH: 8 })
	})
})
