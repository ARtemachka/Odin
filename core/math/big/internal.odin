//+ignore
package math_big

/*
	Copyright 2021 Jeroen van Rijn <nom@duclavier.com>.
	Made available under Odin's BSD-2 license.

	A BigInt implementation in Odin.
	For the theoretical underpinnings, see Knuth's The Art of Computer Programming, Volume 2, section 4.3.
	The code started out as an idiomatic source port of libTomMath, which is in the public domain, with thanks.

	==========================    Low-level routines    ==========================

	IMPORTANT: `internal_*` procedures make certain assumptions about their input.

	The public functions that call them are expected to satisfy their sanity check requirements.
	This allows `internal_*` call `internal_*` without paying this overhead multiple times.

	Where errors can occur, they are of course still checked and returned as appropriate.

	When importing `math:core/big` to implement an involved algorithm of your own, you are welcome
	to use these procedures instead of their public counterparts.

	Most inputs and outputs are expected to be passed an initialized `Int`, for example.
	Exceptions include `quotient` and `remainder`, which are allowed to be `nil` when the calling code doesn't need them.

	Check the comments above each `internal_*` implementation to see what constraints it expects to have met.

	We pass the custom allocator to procedures by default using the pattern `context.allocator = allocator`.
	This way we don't have to add `, allocator` at the end of each call.

	TODO: Handle +/- Infinity and NaN.
*/

import "core:mem"
import "core:intrinsics"
import rnd "core:math/rand"

/*
	Low-level addition, unsigned. Handbook of Applied Cryptography, algorithm 14.7.

	Assumptions:
		`dest`, `a` and `b` != `nil` and have been initalized.
*/
internal_int_add_unsigned :: proc(dest, a, b: ^Int, allocator := context.allocator) -> (err: Error) {
	dest := dest; x := a; y := b;
	context.allocator = allocator;

	old_used, min_used, max_used, i: int;

	if x.used < y.used {
		x, y = y, x;
	}

	min_used = y.used;
	max_used = x.used;
	old_used = dest.used;

	if err = internal_grow(dest, max(max_used + 1, _DEFAULT_DIGIT_COUNT)); err != nil { return err; }
	dest.used = max_used + 1;
	/*
		All parameters have been initialized.
	*/

	/* Zero the carry */
	carry := DIGIT(0);

	#no_bounds_check for i = 0; i < min_used; i += 1 {
		/*
			Compute the sum one _DIGIT at a time.
			dest[i] = a[i] + b[i] + carry;
		*/
		dest.digit[i] = x.digit[i] + y.digit[i] + carry;

		/*
			Compute carry
		*/
		carry = dest.digit[i] >> _DIGIT_BITS;
		/*
			Mask away carry from result digit.
		*/
		dest.digit[i] &= _MASK;
	}

	if min_used != max_used {
		/*
			Now copy higher words, if any, in A+B.
			If A or B has more digits, add those in.
		*/
		#no_bounds_check for ; i < max_used; i += 1 {
			dest.digit[i] = x.digit[i] + carry;
			/*
				Compute carry
			*/
			carry = dest.digit[i] >> _DIGIT_BITS;
			/*
				Mask away carry from result digit.
			*/
			dest.digit[i] &= _MASK;
		}
	}
	/*
		Add remaining carry.
	*/
	dest.digit[i] = carry;

	/*
		Zero remainder.
	*/
	internal_zero_unused(dest, old_used);
	/*
		Adjust dest.used based on leading zeroes.
	*/
	return internal_clamp(dest);
}
internal_add_unsigned :: proc { internal_int_add_unsigned, };

/*
	Low-level addition, signed. Handbook of Applied Cryptography, algorithm 14.7.

	Assumptions:
		`dest`, `a` and `b` != `nil` and have been initalized.
*/
internal_int_add_signed :: proc(dest, a, b: ^Int, allocator := context.allocator) -> (err: Error) {
	x := a; y := b;
	context.allocator = allocator;
	/*
		Handle both negative or both positive.
	*/
	if x.sign == y.sign {
		dest.sign = x.sign;
		return #force_inline internal_int_add_unsigned(dest, x, y);
	}

	/*
		One positive, the other negative.
		Subtract the one with the greater magnitude from the other.
		The result gets the sign of the one with the greater magnitude.
	*/
	if #force_inline internal_cmp_mag(a, b) == -1 {
		x, y = y, x;
	}

	dest.sign = x.sign;
	return #force_inline internal_int_sub_unsigned(dest, x, y);
}
internal_add_signed :: proc { internal_int_add_signed, };

/*
	Low-level addition Int+DIGIT, signed. Handbook of Applied Cryptography, algorithm 14.7.

	Assumptions:
		`dest` and `a` != `nil` and have been initalized.
		`dest` is large enough (a.used + 1) to fit result.
*/
internal_int_add_digit :: proc(dest, a: ^Int, digit: DIGIT, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	if err = internal_grow(dest, a.used + 1); err != nil { return err; }
	/*
		Fast paths for destination and input Int being the same.
	*/
	if dest == a {
		/*
			Fast path for dest.digit[0] + digit fits in dest.digit[0] without overflow.
		*/
		if dest.sign == .Zero_or_Positive && (dest.digit[0] + digit < _DIGIT_MAX) {
			dest.digit[0] += digit;
			dest.used += 1;
			return internal_clamp(dest);
		}
		/*
			Can be subtracted from dest.digit[0] without underflow.
		*/
		if a.sign == .Negative && (dest.digit[0] > digit) {
			dest.digit[0] -= digit;
			dest.used += 1;
			return internal_clamp(dest);
		}
	}

	/*
		If `a` is negative and `|a|` >= `digit`, call `dest = |a| - digit`
	*/
	if a.sign == .Negative && (a.used > 1 || a.digit[0] >= digit) {
		/*
			Temporarily fix `a`'s sign.
		*/
		a.sign = .Zero_or_Positive;
		/*
			dest = |a| - digit
		*/
		if err = #force_inline internal_int_add_digit(dest, a, digit); err != nil {
			/*
				Restore a's sign.
			*/
			a.sign = .Negative;
			return err;
		}
		/*
			Restore sign and set `dest` sign.
		*/
		a.sign    = .Negative;
		dest.sign = .Negative;

		return internal_clamp(dest);
	}

	/*
		Remember the currently used number of digits in `dest`.
	*/
	old_used := dest.used;

	/*
		If `a` is positive
	*/
	if a.sign == .Zero_or_Positive {
		/*
			Add digits, use `carry`.
		*/
		i: int;
		carry := digit;
		#no_bounds_check for i = 0; i < a.used; i += 1 {
			dest.digit[i] = a.digit[i] + carry;
			carry = dest.digit[i] >> _DIGIT_BITS;
			dest.digit[i] &= _MASK;
		}
		/*
			Set final carry.
		*/
		dest.digit[i] = carry;
		/*
			Set `dest` size.
		*/
		dest.used = a.used + 1;
	} else {
		/*
			`a` was negative and |a| < digit.
		*/
		dest.used = 1;
		/*
			The result is a single DIGIT.
		*/
		dest.digit[0] = digit - a.digit[0] if a.used == 1 else digit;
	}
	/*
		Sign is always positive.
	*/
	dest.sign = .Zero_or_Positive;

	/*
		Zero remainder.
	*/
	internal_zero_unused(dest, old_used);

	/*
		Adjust dest.used based on leading zeroes.
	*/
	return internal_clamp(dest);	
}
internal_add :: proc { internal_int_add_signed, internal_int_add_digit, };

/*
	Low-level subtraction, dest = number - decrease. Assumes |number| > |decrease|.
	Handbook of Applied Cryptography, algorithm 14.9.

	Assumptions:
		`dest`, `number` and `decrease` != `nil` and have been initalized.
*/
internal_int_sub_unsigned :: proc(dest, number, decrease: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	dest := dest; x := number; y := decrease;
	old_used := dest.used;
	min_used := y.used;
	max_used := x.used;
	i: int;

	if err = grow(dest, max(max_used, _DEFAULT_DIGIT_COUNT)); err != nil { return err; }
	dest.used = max_used;
	/*
		All parameters have been initialized.
	*/

	borrow := DIGIT(0);

	#no_bounds_check for i = 0; i < min_used; i += 1 {
		dest.digit[i] = (x.digit[i] - y.digit[i] - borrow);
		/*
			borrow = carry bit of dest[i]
			Note this saves performing an AND operation since if a carry does occur,
			it will propagate all the way to the MSB.
			As a result a single shift is enough to get the carry.
		*/
		borrow = dest.digit[i] >> ((size_of(DIGIT) * 8) - 1);
		/*
			Clear borrow from dest[i].
		*/
		dest.digit[i] &= _MASK;
	}

	/*
		Now copy higher words if any, e.g. if A has more digits than B
	*/
	#no_bounds_check for ; i < max_used; i += 1 {
		dest.digit[i] = x.digit[i] - borrow;
		/*
			borrow = carry bit of dest[i]
			Note this saves performing an AND operation since if a carry does occur,
			it will propagate all the way to the MSB.
			As a result a single shift is enough to get the carry.
		*/
		borrow = dest.digit[i] >> ((size_of(DIGIT) * 8) - 1);
		/*
			Clear borrow from dest[i].
		*/
		dest.digit[i] &= _MASK;
	}

	/*
		Zero remainder.
	*/
	internal_zero_unused(dest, old_used);

	/*
		Adjust dest.used based on leading zeroes.
	*/
	return internal_clamp(dest);
}
internal_sub_unsigned :: proc { internal_int_sub_unsigned, };

/*
	Low-level subtraction, signed. Handbook of Applied Cryptography, algorithm 14.9.
	dest = number - decrease. Assumes |number| > |decrease|.

	Assumptions:
		`dest`, `number` and `decrease` != `nil` and have been initalized.
*/
internal_int_sub_signed :: proc(dest, number, decrease: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	number := number; decrease := decrease;
	if number.sign != decrease.sign {
		/*
			Subtract a negative from a positive, OR subtract a positive from a negative.
			In either case, ADD their magnitudes and use the sign of the first number.
		*/
		dest.sign = number.sign;
		return #force_inline internal_int_add_unsigned(dest, number, decrease);
	}

	/*
		Subtract a positive from a positive, OR negative from a negative.
		First, take the difference between their magnitudes, then...
	*/
	if #force_inline internal_cmp_mag(number, decrease) == -1 {
		/*
			The second has a larger magnitude.
			The result has the *opposite* sign from the first number.
		*/
		dest.sign = .Negative if number.sign == .Zero_or_Positive else .Zero_or_Positive;
		number, decrease = decrease, number;
	} else {
		/*
			The first has a larger or equal magnitude.
			Copy the sign from the first.
		*/
		dest.sign = number.sign;
	}
	return #force_inline internal_int_sub_unsigned(dest, number, decrease);
}

/*
	Low-level subtraction, signed. Handbook of Applied Cryptography, algorithm 14.9.
	dest = number - decrease. Assumes |number| > |decrease|.

	Assumptions:
		`dest`, `number` != `nil` and have been initalized.
		`dest` is large enough (number.used + 1) to fit result.
*/
internal_int_sub_digit :: proc(dest, number: ^Int, digit: DIGIT, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	if err = internal_grow(dest, number.used + 1); err != nil { return err; }

	dest := dest; digit := digit;
	/*
		All parameters have been initialized.

		Fast paths for destination and input Int being the same.
	*/
	if dest == number {
		/*
			Fast path for `dest` is negative and unsigned addition doesn't overflow the lowest digit.
		*/
		if dest.sign == .Negative && (dest.digit[0] + digit < _DIGIT_MAX) {
			dest.digit[0] += digit;
			return nil;
		}
		/*
			Can be subtracted from dest.digit[0] without underflow.
		*/
		if number.sign == .Zero_or_Positive && (dest.digit[0] > digit) {
			dest.digit[0] -= digit;
			return nil;
		}
	}

	/*
		If `a` is negative, just do an unsigned addition (with fudged signs).
	*/
	if number.sign == .Negative {
		t := number;
		t.sign = .Zero_or_Positive;

		err =  #force_inline internal_int_add_digit(dest, t, digit);
		dest.sign = .Negative;

		internal_clamp(dest);
		return err;
	}

	old_used := dest.used;

	/*
		if `a`<= digit, simply fix the single digit.
	*/
	if number.used == 1 && (number.digit[0] <= digit) || number.used == 0 {
		dest.digit[0] = digit - number.digit[0] if number.used == 1 else digit;
		dest.sign = .Negative;
		dest.used = 1;
	} else {
		dest.sign = .Zero_or_Positive;
		dest.used = number.used;

		/*
			Subtract with carry.
		*/
		carry := digit;

		#no_bounds_check for i := 0; i < number.used; i += 1 {
			dest.digit[i] = number.digit[i] - carry;
			carry = dest.digit[i] >> (_DIGIT_TYPE_BITS - 1);
			dest.digit[i] &= _MASK;
		}
	}

	/*
		Zero remainder.
	*/
	internal_zero_unused(dest, old_used);

	/*
		Adjust dest.used based on leading zeroes.
	*/
	return internal_clamp(dest);
}

internal_sub :: proc { internal_int_sub_signed, internal_int_sub_digit, };

/*
	dest = src  / 2
	dest = src >> 1

	Assumes `dest` and `src` not to be `nil` and have been initialized.
	We make no allocations here.
*/
internal_int_shr1 :: proc(dest, src: ^Int) -> (err: Error) {
	old_used  := dest.used; dest.used = src.used;
	/*
		Carry
	*/
	fwd_carry := DIGIT(0);

	#no_bounds_check for x := dest.used - 1; x >= 0; x -= 1 {
		/*
			Get the carry for the next iteration.
		*/
		src_digit := src.digit[x];
		carry     := src_digit & 1;
		/*
			Shift the current digit, add in carry and store.
		*/
		dest.digit[x] = (src_digit >> 1) | (fwd_carry << (_DIGIT_BITS - 1));
		/*
			Forward carry to next iteration.
		*/
		fwd_carry = carry;
	}

	/*
		Zero remainder.
	*/
	internal_zero_unused(dest, old_used);

	/*
		Adjust dest.used based on leading zeroes.
	*/
	dest.sign = src.sign;
	return internal_clamp(dest);	
}

/*
	dest = src  * 2
	dest = src << 1
*/
internal_int_shl1 :: proc(dest, src: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	if err = internal_copy(dest, src); err != nil { return err; }
	/*
		Grow `dest` to accommodate the additional bits.
	*/
	digits_needed := dest.used + 1;
	if err = internal_grow(dest, digits_needed); err != nil { return err; }
	dest.used = digits_needed;

	mask  := (DIGIT(1) << uint(1)) - DIGIT(1);
	shift := DIGIT(_DIGIT_BITS - 1);
	carry := DIGIT(0);

	#no_bounds_check for x:= 0; x < dest.used; x+= 1 {		
		fwd_carry := (dest.digit[x] >> shift) & mask;
		dest.digit[x] = (dest.digit[x] << uint(1) | carry) & _MASK;
		carry = fwd_carry;
	}
	/*
		Use final carry.
	*/
	if carry != 0 {
		dest.digit[dest.used] = carry;
		dest.used += 1;
	}
	return internal_clamp(dest);
}

/*
	Multiply by a DIGIT.
*/
internal_int_mul_digit :: proc(dest, src: ^Int, multiplier: DIGIT, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;
	assert_if_nil(dest, src);

	if multiplier == 0 {
		return internal_zero(dest);
	}
	if multiplier == 1 {
		return internal_copy(dest, src);
	}

	/*
		Power of two?
	*/
	if multiplier == 2 {
		return #force_inline internal_int_shl1(dest, src);
	}
	if #force_inline platform_int_is_power_of_two(int(multiplier)) {
		ix: int;
		if ix, err = internal_log(multiplier, 2); err != nil { return err; }
		return internal_shl(dest, src, ix);
	}

	/*
		Ensure `dest` is big enough to hold `src` * `multiplier`.
	*/
	if err = grow(dest, max(src.used + 1, _DEFAULT_DIGIT_COUNT)); err != nil { return err; }

	/*
		Save the original used count.
	*/
	old_used := dest.used;
	/*
		Set the sign.
	*/
	dest.sign = src.sign;
	/*
		Set up carry.
	*/
	carry := _WORD(0);
	/*
		Compute columns.
	*/
	ix := 0;
	#no_bounds_check for ; ix < src.used; ix += 1 {
		/*
			Compute product and carry sum for this term
		*/
		product := carry + _WORD(src.digit[ix]) * _WORD(multiplier);
		/*
			Mask off higher bits to get a single DIGIT.
		*/
		dest.digit[ix] = DIGIT(product & _WORD(_MASK));
		/*
			Send carry into next iteration
		*/
		carry = product >> _DIGIT_BITS;
	}

	/*
		Store final carry [if any] and increment used.
	*/
	dest.digit[ix] = DIGIT(carry);
	dest.used = src.used + 1;

	/*
		Zero remainder.
	*/
	internal_zero_unused(dest, old_used);

	return internal_clamp(dest);
}

/*
	High level multiplication (handles sign).
*/
internal_int_mul :: proc(dest, src, multiplier: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;
	/*
		Early out for `multiplier` is zero; Set `dest` to zero.
	*/
	if multiplier.used == 0 || src.used == 0 { return internal_zero(dest); }

	if src == multiplier {
		/*
			Do we need to square?
		*/
		if src.used >= SQR_TOOM_CUTOFF {
			/*
				Use Toom-Cook?
			*/
			err = #force_inline _private_int_sqr_toom(dest, src);
		} else if src.used >= SQR_KARATSUBA_CUTOFF {
			/*
				Karatsuba?
			*/
			err = #force_inline _private_int_sqr_karatsuba(dest, src);
		} else if ((src.used * 2) + 1) < _WARRAY && src.used < (_MAX_COMBA / 2) {
			/*
				Fast comba?
			*/
			err = #force_inline _private_int_sqr_comba(dest, src);
			//err = #force_inline _private_int_sqr(dest, src);
		} else {
			err = #force_inline _private_int_sqr(dest, src);
		}
	} else {
		/*
			Can we use the balance method? Check sizes.
			* The smaller one needs to be larger than the Karatsuba cut-off.
			* The bigger one needs to be at least about one `_MUL_KARATSUBA_CUTOFF` bigger
			* to make some sense, but it depends on architecture, OS, position of the
			* stars... so YMMV.
			* Using it to cut the input into slices small enough for _mul_comba
			* was actually slower on the author's machine, but YMMV.
		*/

		min_used := min(src.used, multiplier.used);
		max_used := max(src.used, multiplier.used);
		digits   := src.used + multiplier.used + 1;

		if        false &&  min_used     >= MUL_KARATSUBA_CUTOFF &&
						    max_used / 2 >= MUL_KARATSUBA_CUTOFF &&
			/*
				Not much effect was observed below a ratio of 1:2, but again: YMMV.
			*/
							max_used     >= 2 * min_used {
			// err = s_mp_mul_balance(a,b,c);
		} else if false && min_used >= MUL_TOOM_CUTOFF {
			// err = s_mp_mul_toom(a, b, c);
		} else if false && min_used >= MUL_KARATSUBA_CUTOFF {
			// err = s_mp_mul_karatsuba(a, b, c);
		} else if digits < _WARRAY && min_used <= _MAX_COMBA {
			/*
				Can we use the fast multiplier?
				* The fast multiplier can be used if the output will
				* have less than MP_WARRAY digits and the number of
				* digits won't affect carry propagation
			*/
			err = #force_inline _private_int_mul_comba(dest, src, multiplier, digits);
		} else {
			err = #force_inline _private_int_mul(dest, src, multiplier, digits);
		}
	}
	neg := src.sign != multiplier.sign;
	dest.sign = .Negative if dest.used > 0 && neg else .Zero_or_Positive;
	return err;
}

internal_mul :: proc { internal_int_mul, internal_int_mul_digit, };

internal_sqr :: proc (dest, src: ^Int, allocator := context.allocator) -> (res: Error) {
	/*
		We call `internal_mul` and not e.g. `_private_int_sqr` because the former
		will dispatch to the optimal implementation depending on the source.
	*/
	return #force_inline internal_mul(dest, src, src, allocator);
}

/*
	divmod.
	Both the quotient and remainder are optional and may be passed a nil.
	`numerator` and `denominator` are expected not to be `nil` and have been initialized.
*/
internal_int_divmod :: proc(quotient, remainder, numerator, denominator: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	if denominator.used == 0 { return .Division_by_Zero; }
	/*
		If numerator < denominator then quotient = 0, remainder = numerator.
	*/
	if #force_inline internal_cmp_mag(numerator, denominator) == -1 {
		if remainder != nil {
			if err = internal_copy(remainder, numerator); err != nil { return err; }
		}
		if quotient != nil {
			internal_zero(quotient);
		}
		return nil;
	}

	if false && (denominator.used > 2 * MUL_KARATSUBA_CUTOFF) && (denominator.used <= (numerator.used/3) * 2) {
		// err = _int_div_recursive(quotient, remainder, numerator, denominator);
	} else {
		when true {
			err = #force_inline _private_int_div_school(quotient, remainder, numerator, denominator);
		} else {
			/*
				NOTE(Jeroen): We no longer need or use `_private_int_div_small`.
				We'll keep it around for a bit until we're reasonably certain div_school is bug free.
			*/
			err = _private_int_div_small(quotient, remainder, numerator, denominator);
		}
	}
	return;
}

/*
	Single digit division (based on routine from MPI).
	The quotient is optional and may be passed a nil.
*/
internal_int_divmod_digit :: proc(quotient, numerator: ^Int, denominator: DIGIT, allocator := context.allocator) -> (remainder: DIGIT, err: Error) {
	context.allocator = allocator;

	/*
		Cannot divide by zero.
	*/
	if denominator == 0 { return 0, .Division_by_Zero; }

	/*
		Quick outs.
	*/
	if denominator == 1 || numerator.used == 0 {
		if quotient != nil {
			return 0, internal_copy(quotient, numerator);
		}
		return 0, err;
	}
	/*
		Power of two?
	*/
	if denominator == 2 {
		if numerator.used > 0 && numerator.digit[0] & 1 != 0 {
			// Remainder is 1 if numerator is odd.
			remainder = 1;
		}
		if quotient == nil {
			return remainder, nil;
		}
		return remainder, internal_shr(quotient, numerator, 1);
	}

	ix: int;
	if platform_int_is_power_of_two(int(denominator)) {
		ix = 1;
		for ix < _DIGIT_BITS && denominator != (1 << uint(ix)) {
			ix += 1;
		}
		remainder = numerator.digit[0] & ((1 << uint(ix)) - 1);
		if quotient == nil {
			return remainder, nil;
		}

		return remainder, internal_shr(quotient, numerator, int(ix));
	}

	/*
		Three?
	*/
	if denominator == 3 {
		return _private_int_div_3(quotient, numerator);
	}

	/*
		No easy answer [c'est la vie].  Just division.
	*/
	q := &Int{};

	if err = internal_grow(q, numerator.used); err != nil { return 0, err; }

	q.used = numerator.used;
	q.sign = numerator.sign;

	w := _WORD(0);

	for ix = numerator.used - 1; ix >= 0; ix -= 1 {
		t := DIGIT(0);
		w = (w << _WORD(_DIGIT_BITS) | _WORD(numerator.digit[ix]));
		if w >= _WORD(denominator) {
			t = DIGIT(w / _WORD(denominator));
			w -= _WORD(t) * _WORD(denominator);
		}
		q.digit[ix] = t;
	}
	remainder = DIGIT(w);

	if quotient != nil {
		internal_clamp(q);
		internal_swap(q, quotient);
	}
	internal_destroy(q);
	return remainder, nil;
}

internal_divmod :: proc { internal_int_divmod, internal_int_divmod_digit, };

/*
	Asssumes quotient, numerator and denominator to have been initialized and not to be nil.
*/
internal_int_div :: proc(quotient, numerator, denominator: ^Int, allocator := context.allocator) -> (err: Error) {
	return #force_inline internal_int_divmod(quotient, nil, numerator, denominator, allocator);
}
internal_div :: proc { internal_int_div, };

/*
	remainder = numerator % denominator.
	0 <= remainder < denominator if denominator > 0
	denominator < remainder <= 0 if denominator < 0

	Asssumes quotient, numerator and denominator to have been initialized and not to be nil.
*/
internal_int_mod :: proc(remainder, numerator, denominator: ^Int, allocator := context.allocator) -> (err: Error) {
	if err = #force_inline internal_int_divmod(nil, remainder, numerator, denominator, allocator); err != nil { return err; }

	if remainder.used == 0 || denominator.sign == remainder.sign { return nil; }

	return #force_inline internal_add(remainder, remainder, numerator, allocator);
}
internal_mod :: proc{ internal_int_mod, };

/*
	remainder = (number + addend) % modulus.
*/
internal_int_addmod :: proc(remainder, number, addend, modulus: ^Int, allocator := context.allocator) -> (err: Error) {
	if err = #force_inline internal_add(remainder, number, addend, allocator); err != nil { return err; }
	return #force_inline internal_mod(remainder, remainder, modulus, allocator);
}
internal_addmod :: proc { internal_int_addmod, };

/*
	remainder = (number - decrease) % modulus.
*/
internal_int_submod :: proc(remainder, number, decrease, modulus: ^Int, allocator := context.allocator) -> (err: Error) {
	if err = #force_inline internal_sub(remainder, number, decrease, allocator); err != nil { return err; }
	return #force_inline internal_mod(remainder, remainder, modulus, allocator);
}
internal_submod :: proc { internal_int_submod, };

/*
	remainder = (number * multiplicand) % modulus.
*/
internal_int_mulmod :: proc(remainder, number, multiplicand, modulus: ^Int, allocator := context.allocator) -> (err: Error) {
	if err = #force_inline internal_mul(remainder, number, multiplicand, allocator); err != nil { return err; }
	return #force_inline internal_mod(remainder, remainder, modulus, allocator);
}
internal_mulmod :: proc { internal_int_mulmod, };

/*
	remainder = (number * number) % modulus.
*/
internal_int_sqrmod :: proc(remainder, number, modulus: ^Int, allocator := context.allocator) -> (err: Error) {
	if err = #force_inline internal_sqr(remainder, number, allocator); err != nil { return err; }
	return #force_inline internal_mod(remainder, remainder, modulus, allocator);
}
internal_sqrmod :: proc { internal_int_sqrmod, };



/*
	TODO: Use Sterling's Approximation to estimate log2(N!) to size the result.
	This way we'll have to reallocate less, possibly not at all.
*/
internal_int_factorial :: proc(res: ^Int, n: int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	if n >= FACTORIAL_BINARY_SPLIT_CUTOFF {
		return #force_inline _private_int_factorial_binary_split(res, n);
	}

	i := len(_factorial_table);
	if n < i {
		return #force_inline internal_set(res, _factorial_table[n]);
	}

	if err = #force_inline internal_set(res, _factorial_table[i - 1]); err != nil { return err; }
	for {
		if err = #force_inline internal_mul(res, res, DIGIT(i)); err != nil || i == n { return err; }
		i += 1;
	}

	return nil;
}

/*
	Returns GCD, LCM or both.

	Assumes `a` and `b` to have been initialized.
	`res_gcd` and `res_lcm` can be nil or ^Int depending on which results are desired.
*/
internal_int_gcd_lcm :: proc(res_gcd, res_lcm, a, b: ^Int, allocator := context.allocator) -> (err: Error) {
	if res_gcd == nil && res_lcm == nil { return nil; }

	return #force_inline _private_int_gcd_lcm(res_gcd, res_lcm, a, b, allocator);
}

/*
	remainder = numerator % (1 << bits)

	Assumes `remainder` and `numerator` both not to be `nil` and `bits` to be >= 0.
*/
internal_int_mod_bits :: proc(remainder, numerator: ^Int, bits: int, allocator := context.allocator) -> (err: Error) {
	/*
		Everything is divisible by 1 << 0 == 1, so this returns 0.
	*/
	if bits == 0 { return internal_zero(remainder); }

	/*
		If the modulus is larger than the value, return the value.
	*/
	err = internal_copy(remainder, numerator);
	if bits >= (numerator.used * _DIGIT_BITS) || err != nil {
		return;
	}

	/*
		Zero digits above the last digit of the modulus.
	*/
	zero_count := (bits / _DIGIT_BITS);
	zero_count += 0 if (bits % _DIGIT_BITS == 0) else 1;

	/*
		Zero remainder. Special case, can't use `internal_zero_unused`.
	*/
	if zero_count > 0 {
		mem.zero_slice(remainder.digit[zero_count:]);
	}

	/*
		Clear the digit that is not completely outside/inside the modulus.
	*/
	remainder.digit[bits / _DIGIT_BITS] &= DIGIT(1 << DIGIT(bits % _DIGIT_BITS)) - DIGIT(1);
	return internal_clamp(remainder);
}

/*
	=============================    Low-level helpers    =============================


	`internal_*` helpers don't return an `Error` like their public counterparts do,
	because they expect not to be passed `nil` or uninitialized inputs.

	This makes them more suitable for `internal_*` functions and some of the
	public ones that have already satisfied these constraints.
*/

/*
	This procedure will return `true` if the `Int` is initialized, `false` if not.
	Assumes `a` not to be `nil`.
*/
internal_int_is_initialized :: #force_inline proc(a: ^Int) -> (initialized: bool) {
	raw := transmute(mem.Raw_Dynamic_Array)a.digit;
	return raw.cap >= _MIN_DIGIT_COUNT;
}
internal_is_initialized :: proc { internal_int_is_initialized, };

/*
	This procedure will return `true` if the `Int` is zero, `false` if not.
	Assumes `a` not to be `nil`.
*/
internal_int_is_zero :: #force_inline proc(a: ^Int) -> (zero: bool) {
	return a.used == 0;
}
internal_is_zero :: proc { internal_int_is_zero, };

/*
	This procedure will return `true` if the `Int` is positive, `false` if not.
	Assumes `a` not to be `nil`.
*/
internal_int_is_positive :: #force_inline proc(a: ^Int) -> (positive: bool) {
	return a.sign == .Zero_or_Positive;
}
internal_is_positive :: proc { internal_int_is_positive, };

/*
	This procedure will return `true` if the `Int` is negative, `false` if not.
	Assumes `a` not to be `nil`.
*/
internal_int_is_negative :: #force_inline proc(a: ^Int) -> (negative: bool) {
	return a.sign == .Negative;
}
internal_is_negative :: proc { internal_int_is_negative, };

/*
	This procedure will return `true` if the `Int` is even, `false` if not.
	Assumes `a` not to be `nil`.
*/
internal_int_is_even :: #force_inline proc(a: ^Int) -> (even: bool) {
	if internal_is_zero(a) { return true; }

	/*
		`a.used` > 0 here, because the above handled `is_zero`.
		We don't need to explicitly test it.
	*/
	return a.digit[0] & 1 == 0;
}
internal_is_even :: proc { internal_int_is_even, };

/*
	This procedure will return `true` if the `Int` is even, `false` if not.
	Assumes `a` not to be `nil`.
*/
internal_int_is_odd :: #force_inline proc(a: ^Int) -> (odd: bool) {
	return !internal_int_is_even(a);
}
internal_is_odd :: proc { internal_int_is_odd, };


/*
	This procedure will return `true` if the `Int` is a power of two, `false` if not.
	Assumes `a` not to be `nil`.
*/
internal_int_is_power_of_two :: #force_inline proc(a: ^Int) -> (power_of_two: bool) {
	/*
		Early out for Int == 0.
	*/
	if #force_inline internal_is_zero(a) { return true; }

	/*
		For an `Int` to be a power of two, its bottom limb has to be a power of two.
	*/
	if ! #force_inline platform_int_is_power_of_two(int(a.digit[a.used - 1])) { return false; }

	/*
		We've established that the bottom limb is a power of two.
		If it's the only limb, that makes the entire Int a power of two.
	*/
	if a.used == 1 { return true; }

	/*
		For an `Int` to be a power of two, all limbs except the top one have to be zero.
	*/
	for i := 1; i < a.used && a.digit[i - 1] != 0; i += 1 { return false; }

	return true;
}
internal_is_power_of_two :: proc { internal_int_is_power_of_two, };

/*
	Compare two `Int`s, signed.
	Returns -1 if `a` < `b`, 0 if `a` == `b` and 1 if `b` > `a`.

	Expects `a` and `b` both to be valid `Int`s, i.e. initialized and not `nil`.
*/
internal_int_compare :: #force_inline proc(a, b: ^Int) -> (comparison: int) {
	a_is_negative := #force_inline internal_is_negative(a);

	/*
		Compare based on sign.
	*/
	if a.sign != b.sign { return -1 if a_is_negative else +1; }

	/*
		If `a` is negative, compare in the opposite direction */
	if a_is_negative { return #force_inline internal_compare_magnitude(b, a); }

	return #force_inline internal_compare_magnitude(a, b);
}
internal_compare :: proc { internal_int_compare, internal_int_compare_digit, };
internal_cmp :: internal_compare;

/*
    Compare an `Int` to an unsigned number upto `DIGIT & _MASK`.
    Returns -1 if `a` < `b`, 0 if `a` == `b` and 1 if `b` > `a`.

    Expects: `a` and `b` both to be valid `Int`s, i.e. initialized and not `nil`.
*/
internal_int_compare_digit :: #force_inline proc(a: ^Int, b: DIGIT) -> (comparison: int) {
	a_is_negative := #force_inline internal_is_negative(a);

	switch {
	/*
		Compare based on sign first.
	*/
	case a_is_negative:     return -1;
	/*
		Then compare on magnitude.
	*/
	case a.used > 1:        return +1;
	/*
		We have only one digit. Compare it against `b`.
	*/
	case a.digit[0] < b:    return -1;
	case a.digit[0] == b:   return  0;
	case a.digit[0] > b:    return +1;
	/*
		Unreachable.
		Just here because Odin complains about a missing return value at the bottom of the proc otherwise.
	*/
	case:                   return;
	}
}
internal_compare_digit :: proc { internal_int_compare_digit, };
internal_cmp_digit :: internal_compare_digit;

/*
	Compare the magnitude of two `Int`s, unsigned.
*/
internal_int_compare_magnitude :: #force_inline proc(a, b: ^Int) -> (comparison: int) {
	/*
		Compare based on used digits.
	*/
	if a.used != b.used {
		if a.used > b.used {
			return +1;
		}
		return -1;
	}

	/*
		Same number of used digits, compare based on their value.
	*/
	#no_bounds_check for n := a.used - 1; n >= 0; n -= 1 {
		if a.digit[n] != b.digit[n] {
			if a.digit[n] > b.digit[n] {
				return +1;
			}
			return -1;
		}
	}

   	return 0;
}
internal_compare_magnitude :: proc { internal_int_compare_magnitude, };
internal_cmp_mag :: internal_compare_magnitude;


/*
	=========================    Logs, powers and roots    ============================
*/

/*
	Returns log_base(a).
	Assumes `a` to not be `nil` and have been iniialized.
*/
internal_int_log :: proc(a: ^Int, base: DIGIT) -> (res: int, err: Error) {
	if base < 2 || DIGIT(base) > _DIGIT_MAX { return -1, .Invalid_Argument; }

	if internal_is_negative(a) { return -1, .Math_Domain_Error; }
	if internal_is_zero(a)     { return -1, .Math_Domain_Error; }

	/*
		Fast path for bases that are a power of two.
	*/
	if platform_int_is_power_of_two(int(base)) { return _private_log_power_of_two(a, base); }

	/*
		Fast path for `Int`s that fit within a single `DIGIT`.
	*/
	if a.used == 1 { return internal_log(a.digit[0], DIGIT(base)); }

	return _private_int_log(a, base);

}

/*
	Returns log_base(a), where `a` is a DIGIT.
*/
internal_digit_log :: proc(a: DIGIT, base: DIGIT) -> (log: int, err: Error) {
	/*
		If the number is smaller than the base, it fits within a fraction.
		Therefore, we return 0.
	*/
	if a  < base { return 0, nil; }

	/*
		If a number equals the base, the log is 1.
	*/
	if a == base { return 1, nil; }

	N := _WORD(a);
	bracket_low  := _WORD(1);
	bracket_high := _WORD(base);
	high := 1;
	low  := 0;

	for bracket_high < N {
		low = high;
		bracket_low = bracket_high;
		high <<= 1;
		bracket_high *= bracket_high;
	}

	for high - low > 1 {
		mid := (low + high) >> 1;
		bracket_mid := bracket_low * #force_inline internal_small_pow(_WORD(base), _WORD(mid - low));

		if N < bracket_mid {
			high = mid;
			bracket_high = bracket_mid;
		}
		if N > bracket_mid {
			low = mid;
			bracket_low = bracket_mid;
		}
		if N == bracket_mid {
			return mid, nil;
		}
	}

	if bracket_high == N {
		return high, nil;
	} else {
		return low, nil;
	}
}
internal_log :: proc { internal_int_log, internal_digit_log, };

/*
	Calculate dest = base^power using a square-multiply algorithm.
	Assumes `dest` and `base` not to be `nil` and to have been initialized.
*/
internal_int_pow :: proc(dest, base: ^Int, power: int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	power := power;
	/*
		Early outs.
	*/
	if #force_inline internal_is_zero(base) {
		/*
			A zero base is a special case.
		*/
		if power  < 0 {
			if err = internal_zero(dest); err != nil { return err; }
			return .Math_Domain_Error;
		}
		if power == 0 { return  internal_one(dest); }
		if power  > 0 { return internal_zero(dest); }

	}
	if power < 0 {
		/*
			Fraction, so we'll return zero.
		*/
		return internal_zero(dest);
	}
	switch(power) {
	case 0:
		/*
			Any base to the power zero is one.
		*/
		return #force_inline internal_one(dest);
	case 1:
		/*
			Any base to the power one is itself.
		*/
		return copy(dest, base);
	case 2:
		return #force_inline internal_sqr(dest, base);
	}

	g := &Int{};
	if err = internal_copy(g, base); err != nil { return err; }

	/*
		Set initial result.
	*/
	if err = internal_one(dest); err != nil { return err; }

	loop: for power > 0 {
		/*
			If the bit is set, multiply.
		*/
		if power & 1 != 0 {
			if err = internal_mul(dest, g, dest); err != nil {
				break loop;
			}
		}
		/*
			Square.
		*/
		if power > 1 {
			if err = #force_inline internal_sqr(g, g); err != nil {
				break loop;
			}
		}

		/* shift to next bit */
		power >>= 1;
	}

	internal_destroy(g);
	return err;
}

/*
	Calculate `dest = base^power`.
	Assumes `dest` not to be `nil` and to have been initialized.
*/
internal_int_pow_int :: proc(dest: ^Int, base, power: int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	base_t := &Int{};
	defer internal_destroy(base_t);

	if err = internal_set(base_t, base); err != nil { return err; }

	return #force_inline internal_int_pow(dest, base_t, power);
}

internal_pow :: proc { internal_int_pow, internal_int_pow_int, };
internal_exp :: pow;

/*

*/
internal_small_pow :: proc(base: _WORD, exponent: _WORD) -> (result: _WORD) {
	exponent := exponent; base := base;
	result = _WORD(1);

	for exponent != 0 {
		if exponent & 1 == 1 {
			result *= base;
		}
		exponent >>= 1;
		base *= base;
	}
	return result;
}

/*
	This function is less generic than `root_n`, simpler and faster.
	Assumes `dest` and `src` not to be `nil` and to have been initialized.
*/
internal_int_sqrt :: proc(dest, src: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	/*
		Must be positive.
	*/
	if #force_inline internal_is_negative(src)  { return .Invalid_Argument; }

	/*
		Easy out. If src is zero, so is dest.
	*/
	if #force_inline internal_is_zero(src)      { return internal_zero(dest); }

	/*
		Set up temporaries.
	*/
	x, y, t1, t2 := &Int{}, &Int{}, &Int{}, &Int{};
	defer internal_destroy(x, y, t1, t2);

	count := #force_inline internal_count_bits(src);

	a, b := count >> 1, count & 1;
	if err = internal_int_power_of_two(x, a+b, allocator);   err != nil { return err; }

	for {
		/*
			y = (x + n // x) // 2
		*/
		if err = internal_div(t1, src, x); err != nil { return err; }
		if err = internal_add(t2, t1, x);  err != nil { return err; }
		if err = internal_shr(y, t2, 1);   err != nil { return err; }

		if c := internal_cmp(y, x); c == 0 || c == 1 {
			internal_swap(dest, x);
			return nil;
		}
		internal_swap(x, y);
	}

	internal_swap(dest, x);
	return err;
}
internal_sqrt :: proc { internal_int_sqrt, };


/*
	Find the nth root of an Integer.
	Result found such that `(dest)**n <= src` and `(dest+1)**n > src`

	This algorithm uses Newton's approximation `x[i+1] = x[i] - f(x[i])/f'(x[i])`,
	which will find the root in `log(n)` time where each step involves a fair bit.

	Assumes `dest` and `src` not to be `nil` and have been initialized.
*/
internal_int_root_n :: proc(dest, src: ^Int, n: int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	/*
		Fast path for n == 2
	*/
	if n == 2 { return #force_inline internal_sqrt(dest, src); }

	if n < 0 || n > int(_DIGIT_MAX) { return .Invalid_Argument; }

	if n & 1 == 0 && #force_inline internal_is_negative(src) { return .Invalid_Argument; }

	/*
		Set up temporaries.
	*/
	t1, t2, t3, a := &Int{}, &Int{}, &Int{}, &Int{};
	defer internal_destroy(t1, t2, t3);

	/*
		If `src` is negative fudge the sign but keep track.
	*/
	a.sign  = .Zero_or_Positive;
	a.used  = src.used;
	a.digit = src.digit;

	/*
		If "n" is larger than INT_MAX it is also larger than
		log_2(src) because the bit-length of the "src" is measured
		with an int and hence the root is always < 2 (two).
	*/
	if n > max(int) / 2 {
		err = set(dest, 1);
		dest.sign = a.sign;
		return err;
	}

	/*
		Compute seed: 2^(log_2(src)/n + 2)
	*/
	ilog2 := internal_count_bits(src);

	/*
		"src" is smaller than max(int), we can cast safely.
	*/
	if ilog2 < n {
		err = internal_one(dest);
		dest.sign = a.sign;
		return err;
	}

	ilog2 /= n;
	if ilog2 == 0 {
		err = internal_one(dest);
		dest.sign = a.sign;
		return err;
	}

	/*
		Start value must be larger than root.
	*/
	ilog2 += 2;
	if err = internal_int_power_of_two(t2, ilog2); err != nil { return err; }

	c: int;
	iterations := 0;
	for {
		/* t1 = t2 */
		if err = internal_copy(t1, t2); err != nil { return err; }

		/* t2 = t1 - ((t1**b - a) / (b * t1**(b-1))) */

		/* t3 = t1**(b-1) */
		if err = internal_pow(t3, t1, n-1); err != nil { return err; }

		/* numerator */
		/* t2 = t1**b */
		if err = internal_mul(t2, t1, t3); err != nil { return err; }

		/* t2 = t1**b - a */
		if err = internal_sub(t2, t2, a); err != nil { return err; }

		/* denominator */
		/* t3 = t1**(b-1) * b  */
		if err = internal_mul(t3, t3, DIGIT(n)); err != nil { return err; }

		/* t3 = (t1**b - a)/(b * t1**(b-1)) */
		if err = internal_div(t3, t2, t3); err != nil { return err; }
		if err = internal_sub(t2, t1, t3); err != nil { return err; }

		/*
			 Number of rounds is at most log_2(root). If it is more it
			 got stuck, so break out of the loop and do the rest manually.
		*/
		if ilog2 -= 1;    ilog2 == 0 { break; }
		if internal_cmp(t1, t2) == 0 { break; }

		iterations += 1;
		if iterations == MAX_ITERATIONS_ROOT_N {
			return .Max_Iterations_Reached;
		}
	}

	/*						Result can be off by a few so check.					*/
	/* Loop beneath can overshoot by one if found root is smaller than actual root. */

	iterations = 0;
	for {
		if err = internal_pow(t2, t1, n); err != nil { return err; }

		c = internal_cmp(t2, a);
		if c == 0 {
			swap(dest, t1);
			return nil;
		} else if c == -1 {
			if err = internal_add(t1, t1, DIGIT(1)); err != nil { return err; }
		} else {
			break;
		}

		iterations += 1;
		if iterations == MAX_ITERATIONS_ROOT_N {
			return .Max_Iterations_Reached;
		}
	}

	iterations = 0;
	/*
		Correct overshoot from above or from recurrence.
		*/
	for {
		if err = internal_pow(t2, t1, n); err != nil { return err; }
	
		if internal_cmp(t2, a) != 1 { break; }
		
		if err = internal_sub(t1, t1, DIGIT(1)); err != nil { return err; }

		iterations += 1;
		if iterations == MAX_ITERATIONS_ROOT_N {
			return .Max_Iterations_Reached;
		}
	}

	/*
		Set the result.
	*/
	internal_swap(dest, t1);

	/*
		Set the sign of the result.
	*/
	dest.sign = src.sign;

	return err;
}
internal_root_n :: proc { internal_int_root_n, };

/*
	Other internal helpers
*/

/*
	Deallocates the backing memory of one or more `Int`s.
	Asssumes none of the `integers` to be a `nil`.
*/
internal_int_destroy :: proc(integers: ..^Int) {
	integers := integers;

	for a in &integers {
		raw := transmute(mem.Raw_Dynamic_Array)a.digit;
		if raw.cap > 0 {
			mem.zero_slice(a.digit[:]);
			free(&a.digit[0]);
		}
		a = &Int{};
	}
}
internal_destroy :: proc{ internal_int_destroy, };

/*
	Helpers to set an `Int` to a specific value.
*/
internal_int_set_from_integer :: proc(dest: ^Int, src: $T, minimize := false, allocator := context.allocator) -> (err: Error)
	where intrinsics.type_is_integer(T) {
	context.allocator = allocator;

	src := src;

	if err = internal_error_if_immutable(dest); err != nil { return err; }
	/*
		Most internal procs asssume an Int to have already been initialize,
		but as this is one of the procs that initializes, we have to check the following.
	*/
	if err = internal_clear_if_uninitialized_single(dest); err != nil { return err; }

	dest.flags = {}; // We're not -Inf, Inf, NaN or Immutable.

	dest.used  = 0;
	dest.sign = .Zero_or_Positive if src >= 0 else .Negative;
	src = internal_abs(src);

	#no_bounds_check for src != 0 {
		dest.digit[dest.used] = DIGIT(src) & _MASK;
		dest.used += 1;
		src >>= _DIGIT_BITS;
	}
	internal_zero_unused(dest);
	return nil;
}

internal_set :: proc { internal_int_set_from_integer, internal_int_copy };

internal_copy_digits :: #force_inline proc(dest, src: ^Int, digits: int) -> (err: Error) {
	if err = #force_inline internal_error_if_immutable(dest); err != nil { return err; }

	/*
		If dest == src, do nothing
	*/
	if (dest == src) { return nil; }

	#force_inline mem.copy_non_overlapping(&dest.digit[0], &src.digit[0], size_of(DIGIT) * digits);
	return nil;
}

/*
	Copy one `Int` to another.
*/
internal_int_copy :: proc(dest, src: ^Int, minimize := false, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	/*
		If dest == src, do nothing
	*/
	if (dest == src) { return nil; }

	if err = internal_error_if_immutable(dest); err != nil { return err; }

	/*
		Grow `dest` to fit `src`.
		If `dest` is not yet initialized, it will be using `allocator`.
	*/
	needed := src.used if minimize else max(src.used, _DEFAULT_DIGIT_COUNT);

	if err = internal_grow(dest, needed, minimize); err != nil { return err; }

	/*
		Copy everything over and zero high digits.
	*/
	internal_copy_digits(dest, src, src.used);

	dest.used  = src.used;
	dest.sign  = src.sign;
	dest.flags = src.flags &~ {.Immutable};

	internal_zero_unused(dest);
	return nil;
}
internal_copy :: proc { internal_int_copy, };

/*
	In normal code, you can also write `a, b = b, a`.
	However, that only swaps within the current scope.
	This helper swaps completely.
*/
internal_int_swap :: #force_inline proc(a, b: ^Int) {
	a := a; b := b;

	a.used,  b.used  = b.used,  a.used;
	a.sign,  b.sign  = b.sign,  a.sign;
	a.digit, b.digit = b.digit, a.digit;
}
internal_swap :: proc { internal_int_swap, };

/*
	Set `dest` to |`src`|.
*/
internal_int_abs :: proc(dest, src: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	/*
		If `dest == src`, just fix `dest`'s sign.
	*/
	if (dest == src) {
		dest.sign = .Zero_or_Positive;
		return nil;
	}

	/*
		Copy `src` to `dest`
	*/
	if err = internal_copy(dest, src); err != nil {
		return err;
	}

	/*
		Fix sign.
	*/
	dest.sign = .Zero_or_Positive;
	return nil;
}

internal_platform_abs :: proc(n: $T) -> T where intrinsics.type_is_integer(T) {
	return n if n >= 0 else -n;
}
internal_abs :: proc{ internal_int_abs, internal_platform_abs, };

/*
	Set `dest` to `-src`.
*/
internal_int_neg :: proc(dest, src: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	/*
		If `dest == src`, just fix `dest`'s sign.
	*/
	sign := Sign.Negative;
	if #force_inline internal_is_zero(src) || #force_inline internal_is_negative(src) {
		sign = .Zero_or_Positive;
	}
	if dest == src {
		dest.sign = sign;
		return nil;
	}
	/*
		Copy `src` to `dest`
	*/
	if err = internal_copy(dest, src); err != nil { return err; }

	/*
		Fix sign.
	*/
	dest.sign = sign;
	return nil;
}
internal_neg :: proc { internal_int_neg, };


/*
	Helpers to extract values from the `Int`.
*/
internal_int_bitfield_extract_single :: proc(a: ^Int, offset: int) -> (bit: _WORD, err: Error) {
	return #force_inline int_bitfield_extract(a, offset, 1);
}

internal_int_bitfield_extract :: proc(a: ^Int, offset, count: int) -> (res: _WORD, err: Error) #no_bounds_check {
	/*
		Early out for single bit.
	*/
	if count == 1 {
		limb := offset / _DIGIT_BITS;
		if limb < 0 || limb >= a.used  { return 0, .Invalid_Argument; }
		i := _WORD(1 << _WORD((offset % _DIGIT_BITS)));
		return 1 if ((_WORD(a.digit[limb]) & i) != 0) else 0, nil;
	}

	if count > _WORD_BITS || count < 1 { return 0, .Invalid_Argument; }

	/*
		There are 3 possible cases.
		-	[offset:][:count] covers 1 DIGIT,
				e.g. offset:  0, count:  60 = bits 0..59
		-	[offset:][:count] covers 2 DIGITS,
				e.g. offset:  5, count:  60 = bits 5..59, 0..4
				e.g. offset:  0, count: 120 = bits 0..59, 60..119
		-	[offset:][:count] covers 3 DIGITS,
				e.g. offset: 40, count: 100 = bits 40..59, 0..59, 0..19
				e.g. offset: 40, count: 120 = bits 40..59, 0..59, 0..39
	*/

	limb        := offset / _DIGIT_BITS;
	bits_left   := count;
	bits_offset := offset % _DIGIT_BITS;

	num_bits    := min(bits_left, _DIGIT_BITS - bits_offset);

	shift       := offset % _DIGIT_BITS;
	mask        := (_WORD(1) << uint(num_bits)) - 1;
	res          = (_WORD(a.digit[limb]) >> uint(shift)) & mask;

	bits_left -= num_bits;
	if bits_left == 0 { return res, nil; }

	res_shift := num_bits;
	num_bits   = min(bits_left, _DIGIT_BITS);
	mask       = (1 << uint(num_bits)) - 1;

	res |= (_WORD(a.digit[limb + 1]) & mask) << uint(res_shift);

	bits_left -= num_bits;
	if bits_left == 0 { return res, nil; }

	mask     = (1 << uint(bits_left)) - 1;
	res_shift += _DIGIT_BITS;

	res |= (_WORD(a.digit[limb + 2]) & mask) << uint(res_shift);

	return res, nil;
}

/*
	Resize backing store.
	We don't need to pass the allocator, because the storage itself stores it.

	Assumes `a` not to be `nil`, and to have already been initialized.
*/
internal_int_shrink :: proc(a: ^Int) -> (err: Error) {
	needed := max(_MIN_DIGIT_COUNT, a.used);

	if a.used != needed { return internal_grow(a, needed, true); }
	return nil;
}
internal_shrink :: proc { internal_int_shrink, };

internal_int_grow :: proc(a: ^Int, digits: int, allow_shrink := false, allocator := context.allocator) -> (err: Error) {
	raw := transmute(mem.Raw_Dynamic_Array)a.digit;

	/*
		We need at least _MIN_DIGIT_COUNT or a.used digits, whichever is bigger.
		The caller is asking for `digits`. Let's be accomodating.
	*/
	needed := max(_MIN_DIGIT_COUNT, a.used, digits);
	if !allow_shrink {
		needed = max(needed, raw.cap);
	}

	/*
		If not yet iniialized, initialize the `digit` backing with the allocator we were passed.
	*/
	if raw.cap == 0 {
		a.digit = mem.make_dynamic_array_len_cap([dynamic]DIGIT, needed, needed, allocator);
	} else if raw.cap != needed {
		/*
			`[dynamic]DIGIT` already knows what allocator was used for it, so resize will do the right thing.
		*/
		resize(&a.digit, needed);
	}
	/*
		Let's see if the allocation/resize worked as expected.
	*/
	if len(a.digit) != needed {
		return .Out_Of_Memory;
	}
	return nil;
}
internal_grow :: proc { internal_int_grow, };

/*
	Clear `Int` and resize it to the default size.
	Assumes `a` not to be `nil`.
*/
internal_int_clear :: proc(a: ^Int, minimize := false, allocator := context.allocator) -> (err: Error) {
	raw := transmute(mem.Raw_Dynamic_Array)a.digit;
	if raw.cap != 0 {
		mem.zero_slice(a.digit[:a.used]);
	}
	a.sign = .Zero_or_Positive;
	a.used = 0;

	return #force_inline internal_grow(a, a.used, minimize, allocator);
}
internal_clear :: proc { internal_int_clear, };
internal_zero  :: internal_clear;

/*
	Set the `Int` to 1 and optionally shrink it to the minimum backing size.
*/
internal_int_one :: proc(a: ^Int, minimize := false, allocator := context.allocator) -> (err: Error) {
	return internal_copy(a, INT_ONE, minimize, allocator);
}
internal_one :: proc { internal_int_one, };

/*
	Set the `Int` to -1 and optionally shrink it to the minimum backing size.
*/
internal_int_minus_one :: proc(a: ^Int, minimize := false, allocator := context.allocator) -> (err: Error) {
	return internal_copy(a, INT_MINUS_ONE, minimize, allocator);
}
internal_minus_one :: proc { internal_int_minus_one, };

/*
	Set the `Int` to Inf and optionally shrink it to the minimum backing size.
*/
internal_int_inf :: proc(a: ^Int, minimize := false, allocator := context.allocator) -> (err: Error) {
	return internal_copy(a, INT_INF, minimize, allocator);
}
internal_inf :: proc { internal_int_inf, };

/*
	Set the `Int` to -Inf and optionally shrink it to the minimum backing size.
*/
internal_int_minus_inf :: proc(a: ^Int, minimize := false, allocator := context.allocator) -> (err: Error) {
	return internal_copy(a, INT_MINUS_INF, minimize, allocator);
}
internal_minus_inf :: proc { internal_int_inf, };

/*
	Set the `Int` to NaN and optionally shrink it to the minimum backing size.
*/
internal_int_nan :: proc(a: ^Int, minimize := false, allocator := context.allocator) -> (err: Error) {
	return internal_copy(a, INT_NAN, minimize, allocator);
}
internal_nan :: proc { internal_int_nan, };

internal_int_power_of_two :: proc(a: ^Int, power: int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	if power < 0 || power > _MAX_BIT_COUNT { return .Invalid_Argument; }

	/*
		Grow to accomodate the single bit.
	*/
	a.used = (power / _DIGIT_BITS) + 1;
	if err = internal_grow(a, a.used); err != nil { return err; }
	/*
		Zero the entirety.
	*/
	mem.zero_slice(a.digit[:]);

	/*
		Set the bit.
	*/
	a.digit[power / _DIGIT_BITS] = 1 << uint((power % _DIGIT_BITS));
	return nil;
}

internal_int_get_u128 :: proc(a: ^Int) -> (res: u128, err: Error) {
	return internal_int_get(a, u128);
}
internal_get_u128 :: proc { internal_int_get_u128, };

internal_int_get_i128 :: proc(a: ^Int) -> (res: i128, err: Error) {
	return internal_int_get(a, i128);
}
internal_get_i128 :: proc { internal_int_get_i128, };

internal_int_get_u64 :: proc(a: ^Int) -> (res: u64, err: Error) {
	return internal_int_get(a, u64);
}
internal_get_u64 :: proc { internal_int_get_u64, };

internal_int_get_i64 :: proc(a: ^Int) -> (res: i64, err: Error) {
	return internal_int_get(a, i64);
}
internal_get_i64 :: proc { internal_int_get_i64, };

internal_int_get_u32 :: proc(a: ^Int) -> (res: u32, err: Error) {
	return internal_int_get(a, u32);
}
internal_get_u32 :: proc { internal_int_get_u32, };

internal_int_get_i32 :: proc(a: ^Int) -> (res: i32, err: Error) {
	return internal_int_get(a, i32);
}
internal_get_i32 :: proc { internal_int_get_i32, };

/*
	TODO: Think about using `count_bits` to check if the value could be returned completely,
	and maybe return max(T), .Integer_Overflow if not?
*/
internal_int_get :: proc(a: ^Int, $T: typeid) -> (res: T, err: Error) where intrinsics.type_is_integer(T) {
	size_in_bits := int(size_of(T) * 8);
	i := int((size_in_bits + _DIGIT_BITS - 1) / _DIGIT_BITS);
	i  = min(int(a.used), i);

	#no_bounds_check for ; i >= 0; i -= 1 {
		res <<= uint(0) if size_in_bits <= _DIGIT_BITS else _DIGIT_BITS;
		res |= T(a.digit[i]);
		if size_in_bits <= _DIGIT_BITS {
			break;
		};
	}

	when !intrinsics.type_is_unsigned(T) {
		/*
			Mask off sign bit.
		*/
		res ~= 1 << uint(size_in_bits - 1);
		/*
			Set the sign.
		*/
		if a.sign == .Negative { res = -res; }
	}
	return;
}
internal_get :: proc { internal_int_get, };

internal_int_get_float :: proc(a: ^Int) -> (res: f64, err: Error) {
	l   := min(a.used, 17); // log2(max(f64)) is approximately 1020, or 17 legs.
	fac := f64(1 << _DIGIT_BITS);
	d   := 0.0;

	#no_bounds_check for i := l; i >= 0; i -= 1 {
		d = (d * fac) + f64(a.digit[i]);
	}

	res = -d if a.sign == .Negative else d;
	return;
}

/*
	The `and`, `or` and `xor` binops differ in two lines only.
	We could handle those with a switch, but that adds overhead.

	TODO: Implement versions that take a DIGIT immediate.
*/

/*
	2's complement `and`, returns `dest = a & b;`
*/
internal_int_and :: proc(dest, a, b: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	used := max(a.used, b.used) + 1;
	/*
		Grow the destination to accomodate the result.
	*/
	if err = internal_grow(dest, used); err != nil { return err; }

	neg_a := #force_inline internal_is_negative(a);
	neg_b := #force_inline internal_is_negative(b);
	neg   := neg_a && neg_b;

	ac, bc, cc := DIGIT(1), DIGIT(1), DIGIT(1);

	#no_bounds_check for i := 0; i < used; i += 1 {
		x, y: DIGIT;

		/*
			Convert to 2's complement if negative.
		*/
		if neg_a {
			ac += _MASK if i >= a.used else (~a.digit[i] & _MASK);
			x = ac & _MASK;
			ac >>= _DIGIT_BITS;
		} else {
			x = 0 if i >= a.used else a.digit[i];
		}

		/*
			Convert to 2's complement if negative.
		*/
		if neg_b {
			bc += _MASK if i >= b.used else (~b.digit[i] & _MASK);
			y = bc & _MASK;
			bc >>= _DIGIT_BITS;
		} else {
			y = 0 if i >= b.used else b.digit[i];
		}

		dest.digit[i] = x & y;

		/*
			Convert to to sign-magnitude if negative.
		*/
		if neg {
			cc += ~dest.digit[i] & _MASK;
			dest.digit[i] = cc & _MASK;
			cc >>= _DIGIT_BITS;
		}
	}

	dest.used = used;
	dest.sign = .Negative if neg else .Zero_or_Positive;
	return internal_clamp(dest);
}
internal_and :: proc { internal_int_and, };

/*
	2's complement `or`, returns `dest = a | b;`
*/
internal_int_or :: proc(dest, a, b: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	used := max(a.used, b.used) + 1;
	/*
		Grow the destination to accomodate the result.
	*/
	if err = internal_grow(dest, used); err != nil { return err; }

	neg_a := #force_inline internal_is_negative(a);
	neg_b := #force_inline internal_is_negative(b);
	neg   := neg_a || neg_b;

	ac, bc, cc := DIGIT(1), DIGIT(1), DIGIT(1);

	#no_bounds_check for i := 0; i < used; i += 1 {
		x, y: DIGIT;

		/*
			Convert to 2's complement if negative.
		*/
		if neg_a {
			ac += _MASK if i >= a.used else (~a.digit[i] & _MASK);
			x = ac & _MASK;
			ac >>= _DIGIT_BITS;
		} else {
			x = 0 if i >= a.used else a.digit[i];
		}

		/*
			Convert to 2's complement if negative.
		*/
		if neg_b {
			bc += _MASK if i >= b.used else (~b.digit[i] & _MASK);
			y = bc & _MASK;
			bc >>= _DIGIT_BITS;
		} else {
			y = 0 if i >= b.used else b.digit[i];
		}

		dest.digit[i] = x | y;

		/*
			Convert to to sign-magnitude if negative.
		*/
		if neg {
			cc += ~dest.digit[i] & _MASK;
			dest.digit[i] = cc & _MASK;
			cc >>= _DIGIT_BITS;
		}
	}

	dest.used = used;
	dest.sign = .Negative if neg else .Zero_or_Positive;
	return internal_clamp(dest);
}
internal_or :: proc { internal_int_or, };

/*
	2's complement `xor`, returns `dest = a ~ b;`
*/
internal_int_xor :: proc(dest, a, b: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	used := max(a.used, b.used) + 1;
	/*
		Grow the destination to accomodate the result.
	*/
	if err = internal_grow(dest, used); err != nil { return err; }

	neg_a := #force_inline internal_is_negative(a);
	neg_b := #force_inline internal_is_negative(b);
	neg   := neg_a != neg_b;

	ac, bc, cc := DIGIT(1), DIGIT(1), DIGIT(1);

	#no_bounds_check for i := 0; i < used; i += 1 {
		x, y: DIGIT;

		/*
			Convert to 2's complement if negative.
		*/
		if neg_a {
			ac += _MASK if i >= a.used else (~a.digit[i] & _MASK);
			x = ac & _MASK;
			ac >>= _DIGIT_BITS;
		} else {
			x = 0 if i >= a.used else a.digit[i];
		}

		/*
			Convert to 2's complement if negative.
		*/
		if neg_b {
			bc += _MASK if i >= b.used else (~b.digit[i] & _MASK);
			y = bc & _MASK;
			bc >>= _DIGIT_BITS;
		} else {
			y = 0 if i >= b.used else b.digit[i];
		}

		dest.digit[i] = x ~ y;

		/*
			Convert to to sign-magnitude if negative.
		*/
		if neg {
			cc += ~dest.digit[i] & _MASK;
			dest.digit[i] = cc & _MASK;
			cc >>= _DIGIT_BITS;
		}
	}

	dest.used = used;
	dest.sign = .Negative if neg else .Zero_or_Positive;
	return internal_clamp(dest);
}
internal_xor :: proc { internal_int_xor, };

/*
	dest = ~src
*/
internal_int_complement :: proc(dest, src: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	/*
		Temporarily fix sign.
	*/
	old_sign := src.sign;

	neg := #force_inline internal_is_zero(src) || #force_inline internal_is_positive(src);

	src.sign = .Negative if neg else .Zero_or_Positive;

	err = #force_inline internal_sub(dest, src, 1);
	/*
		Restore sign.
	*/
	src.sign = old_sign;

	return err;
}
internal_complement :: proc { internal_int_complement, };

/*
	quotient, remainder := numerator >> bits;
	`remainder` is allowed to be passed a `nil`, in which case `mod` won't be computed.
*/
internal_int_shrmod :: proc(quotient, remainder, numerator: ^Int, bits: int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	bits := bits;
	if bits < 0 { return .Invalid_Argument; }

	if err = internal_copy(quotient, numerator); err != nil { return err; }

	/*
		Shift right by a certain bit count (store quotient and optional remainder.)
	   `numerator` should not be used after this.
	*/
	if remainder != nil {
		if err = internal_int_mod_bits(remainder, numerator, bits); err != nil { return err; }
	}

	/*
		Shift by as many digits in the bit count.
	*/
	if bits >= _DIGIT_BITS {
		if err = internal_shr_digit(quotient, bits / _DIGIT_BITS); err != nil { return err; }
	}

	/*
		Shift any bit count < _DIGIT_BITS.
	*/
	bits %= _DIGIT_BITS;
	if bits != 0 {
		mask  := DIGIT(1 << uint(bits)) - 1;
		shift := DIGIT(_DIGIT_BITS - bits);
		carry := DIGIT(0);

		#no_bounds_check for x := quotient.used - 1; x >= 0; x -= 1 {
			/*
				Get the lower bits of this word in a temp.
			*/
			fwd_carry := quotient.digit[x] & mask;

			/*
				Shift the current word and mix in the carry bits from the previous word.
			*/
	        quotient.digit[x] = (quotient.digit[x] >> uint(bits)) | (carry << shift);

	        /*
	        	Update carry from forward carry.
	        */
	        carry = fwd_carry;
		}

	}
	return internal_clamp(numerator);
}
internal_shrmod :: proc { internal_int_shrmod, };

internal_int_shr :: proc(dest, source: ^Int, bits: int, allocator := context.allocator) -> (err: Error) {
	return #force_inline internal_shrmod(dest, nil, source, bits, allocator);
}
internal_shr :: proc { internal_int_shr, };

/*
	Shift right by `digits` * _DIGIT_BITS bits.
*/
internal_int_shr_digit :: proc(quotient: ^Int, digits: int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	if digits <= 0 { return nil; }

	/*
		If digits > used simply zero and return.
	*/
	if digits > quotient.used { return internal_zero(quotient); }

   	/*
		Much like `int_shl_digit`, this is implemented using a sliding window,
		except the window goes the other way around.

		b-2 | b-1 | b0 | b1 | b2 | ... | bb |   ---->
		            /\                   |      ---->
		             \-------------------/      ---->
    */

	#no_bounds_check for x := 0; x < (quotient.used - digits); x += 1 {
    	quotient.digit[x] = quotient.digit[x + digits];
	}
	quotient.used -= digits;
	internal_zero_unused(quotient);
	return internal_clamp(quotient);
}
internal_shr_digit :: proc { internal_int_shr_digit, };

/*
	Shift right by a certain bit count with sign extension.
*/
internal_int_shr_signed :: proc(dest, src: ^Int, bits: int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	if src.sign == .Zero_or_Positive {
		return internal_shr(dest, src, bits);
	}
	if err = internal_int_add_digit(dest, src, DIGIT(1)); err != nil { return err; }

	if err = internal_shr(dest, dest, bits);              err != nil { return err; }
	return internal_sub(dest, src, DIGIT(1));
}

internal_shr_signed :: proc { internal_int_shr_signed, };

/*
	Shift left by a certain bit count.
*/
internal_int_shl :: proc(dest, src: ^Int, bits: int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	bits := bits;

	if bits < 0 { return .Invalid_Argument; }

	if err = internal_copy(dest, src); err != nil { return err; }

	/*
		Grow `dest` to accommodate the additional bits.
	*/
	digits_needed := dest.used + (bits / _DIGIT_BITS) + 1;
	if err = internal_grow(dest, digits_needed); err != nil { return err; }
	dest.used = digits_needed;
	/*
		Shift by as many digits in the bit count as we have.
	*/
	if bits >= _DIGIT_BITS {
		if err = internal_shl_digit(dest, bits / _DIGIT_BITS); err != nil { return err; }
	}

	/*
		Shift any remaining bit count < _DIGIT_BITS
	*/
	bits %= _DIGIT_BITS;
	if bits != 0 {
		mask  := (DIGIT(1) << uint(bits)) - DIGIT(1);
		shift := DIGIT(_DIGIT_BITS - bits);
		carry := DIGIT(0);

		#no_bounds_check for x:= 0; x < dest.used; x+= 1 {
			fwd_carry := (dest.digit[x] >> shift) & mask;
			dest.digit[x] = (dest.digit[x] << uint(bits) | carry) & _MASK;
			carry = fwd_carry;
		}

		/*
			Use final carry.
		*/
		if carry != 0 {
			dest.digit[dest.used] = carry;
			dest.used += 1;
		}
	}
	return internal_clamp(dest);
}
internal_shl :: proc { internal_int_shl, };


/*
	Shift left by `digits` * _DIGIT_BITS bits.
*/
internal_int_shl_digit :: proc(quotient: ^Int, digits: int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	if digits <= 0 { return nil; }

	/*
		No need to shift a zero.
	*/
	if #force_inline internal_is_zero(quotient) { return {}; }

	/*
		Resize `quotient` to accomodate extra digits.
	*/
	if err = #force_inline internal_grow(quotient, quotient.used + digits); err != nil { return err; }

	/*
		Increment the used by the shift amount then copy upwards.
	*/

	/*
		Much like `int_shr_digit`, this is implemented using a sliding window,
		except the window goes the other way around.
    */
    #no_bounds_check for x := quotient.used; x > 0; x -= 1 {
    	quotient.digit[x+digits-1] = quotient.digit[x-1];
    }

   	quotient.used += digits;
    mem.zero_slice(quotient.digit[:digits]);
    return nil;
}
internal_shl_digit :: proc { internal_int_shl_digit, };

/*
	Count bits in an `Int`.
	Assumes `a` not to be `nil` and to have been initialized.
*/
internal_count_bits :: proc(a: ^Int) -> (count: int) {
	/*
		Fast path for zero.
	*/
	if #force_inline internal_is_zero(a) { return {}; }
	/*
		Get the number of DIGITs and use it.
	*/
	count  = (a.used - 1) * _DIGIT_BITS;
	/*
		Take the last DIGIT and count the bits in it.
	*/
	clz   := int(intrinsics.count_leading_zeros(a.digit[a.used - 1]));
	count += (_DIGIT_TYPE_BITS - clz);
	return;
}

/*
	Returns the number of trailing zeroes before the first one.
	Differs from regular `ctz` in that 0 returns 0.

	Assumes `a` not to be `nil` and have been initialized.
*/
internal_int_count_lsb :: proc(a: ^Int) -> (count: int, err: Error) {
	/*
		Easy out.
	*/
	if #force_inline internal_is_zero(a) { return {}, nil; }

	/*
		Scan lower digits until non-zero.
	*/
	x: int;
	#no_bounds_check for x = 0; x < a.used && a.digit[x] == 0; x += 1 {}

	q := a.digit[x];
	x *= _DIGIT_BITS;
	x += internal_count_lsb(q);
	return x, nil;
}

internal_platform_count_lsb :: #force_inline proc(a: $T) -> (count: int)
	where intrinsics.type_is_integer(T) && intrinsics.type_is_unsigned(T) {
	return int(intrinsics.count_trailing_zeros(a)) if a > 0 else 0;
}

internal_count_lsb :: proc { internal_int_count_lsb, internal_platform_count_lsb, };

internal_int_random_digit :: proc(r: ^rnd.Rand = nil) -> (res: DIGIT) {
	when _DIGIT_BITS == 60 { // DIGIT = u64
		return DIGIT(rnd.uint64(r)) & _MASK;
	} else when _DIGIT_BITS == 28 { // DIGIT = u32
		return DIGIT(rnd.uint32(r)) & _MASK;
	} else {
		panic("Unsupported DIGIT size.");
	}

	return 0; // We shouldn't get here.
}

internal_int_rand :: proc(dest: ^Int, bits: int, r: ^rnd.Rand = nil, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	bits := bits;

	if bits <= 0 { return .Invalid_Argument; }

	digits := bits / _DIGIT_BITS;
	bits   %= _DIGIT_BITS;

	if bits > 0 {
		digits += 1;
	}

	if err = #force_inline internal_grow(dest, digits); err != nil { return err; }

	for i := 0; i < digits; i += 1 {
		dest.digit[i] = int_random_digit(r) & _MASK;
	}
	if bits > 0 {
		dest.digit[digits - 1] &= ((1 << uint(bits)) - 1);
	}
	dest.used = digits;
	return nil;
}
internal_rand :: proc { internal_int_rand, };

/*
	Internal helpers.
*/
internal_assert_initialized :: proc(a: ^Int, loc := #caller_location) {
	assert(internal_is_initialized(a), "`Int` was not properly initialized.", loc);
}

internal_clear_if_uninitialized_single :: proc(arg: ^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	if ! #force_inline internal_is_initialized(arg) {
		return #force_inline internal_grow(arg, _DEFAULT_DIGIT_COUNT);
	}
	return err;
}

internal_clear_if_uninitialized_multi :: proc(args: ..^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	for i in args {
		if ! #force_inline internal_is_initialized(i) {
			e := #force_inline internal_grow(i, _DEFAULT_DIGIT_COUNT);
			if e != nil { err = e; }
		}
	}
	return err;
}
internal_clear_if_uninitialized :: proc {internal_clear_if_uninitialized_single, internal_clear_if_uninitialized_multi, };

internal_error_if_immutable_single :: proc(arg: ^Int) -> (err: Error) {
	if arg != nil && .Immutable in arg.flags { return .Assignment_To_Immutable; }
	return nil;
}

internal_error_if_immutable_multi :: proc(args: ..^Int) -> (err: Error) {
	for i in args {
		if i != nil && .Immutable in i.flags { return .Assignment_To_Immutable; }
	}
	return nil;
}
internal_error_if_immutable :: proc {internal_error_if_immutable_single, internal_error_if_immutable_multi, };

/*
	Allocates several `Int`s at once.
*/
internal_int_init_multi :: proc(integers: ..^Int, allocator := context.allocator) -> (err: Error) {
	context.allocator = allocator;

	integers := integers;
	for a in &integers {
		if err = internal_clear(a); err != nil { return err; }
	}
	return nil;
}

internal_init_multi :: proc { internal_int_init_multi, };

/*
	Trim unused digits.

	This is used to ensure that leading zero digits are trimmed and the leading "used" digit will be non-zero.
	Typically very fast.  Also fixes the sign if there are no more leading digits.
*/
internal_clamp :: proc(a: ^Int) -> (err: Error) {
	for a.used > 0 && a.digit[a.used - 1] == 0 { a.used -= 1; }

	if #force_inline internal_is_zero(a) { a.sign = .Zero_or_Positive; }

	return nil;
}


internal_int_zero_unused :: #force_inline proc(dest: ^Int, old_used := -1) {
	/*
		If we don't pass the number of previously used DIGITs, we zero all remaining ones.
	*/
	zero_count: int;
	if old_used == -1 {
		zero_count = len(dest.digit) - dest.used;
	} else {
		zero_count = old_used - dest.used;
	}

	/*
		Zero remainder.
	*/
	if zero_count > 0 && dest.used < len(dest.digit) {
		mem.zero_slice(dest.digit[dest.used:][:zero_count]);
	}
}
internal_zero_unused :: proc { internal_int_zero_unused, };

/*
	==========================    End of low-level routines   ==========================
*/