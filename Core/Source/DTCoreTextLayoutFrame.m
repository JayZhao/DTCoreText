//
//  DTCoreTextLayoutFrame.m
//  DTCoreText
//
//  Created by Oliver Drobnik on 1/24/11.
//  Copyright 2011 Drobnik.com. All rights reserved.
//

#import "DTCoreTextConstants.h"
#import "DTCoreTextLayouter.h"
#import "DTCoreTextLayoutLine.h"
#import "DTCoreTextLayoutFrame.h"
#import "DTCoreTextParagraphStyle.h"
#import "NSDictionary+DTCoreText.h"
#import "DTTextBlock.h"
#import "DTCoreTextFunctions.h"
#import "DTTextAttachment.h"
#import "NSString+Paragraphs.h"
#import "CTLineUtils.h"

#import <DTFoundation/DTLog.h>

// global flag that shows debug frames
static BOOL _DTCoreTextLayoutFramesShouldDrawDebugFrames = NO;

@implementation DTCoreTextLayoutFrame
{
	CTFrameRef _textFrame;
	CTFramesetterRef _framesetter;
	
	NSRange _requestedStringRange;
	NSRange _stringRange;
	
	CGFloat _additionalPaddingAtBottom; // when last line in a text block with padding
	
	NSInteger _numberLinesFitInFrame;
	DTCoreTextLayoutFrameTextBlockHandler _textBlockHandler;
	
	CGFloat _longestLayoutLineWidth;
}

// makes a frame for a specific part of the attributed string of the layouter
- (id)initWithFrame:(CGRect)frame layouter:(DTCoreTextLayouter *)layouter range:(NSRange)range
{
	self = [super init];
	
	if (self)
	{
		_frame = frame;
		
		_attributedStringFragment = [layouter.attributedString mutableCopy];
		
		// determine correct target range
		_requestedStringRange = range;
		NSUInteger stringLength = [_attributedStringFragment length];
		
		if (_requestedStringRange.location >= stringLength)
		{
			return nil;
		}
		
		if (_requestedStringRange.length==0 || NSMaxRange(_requestedStringRange) > stringLength)
		{
			_requestedStringRange.length = stringLength - _requestedStringRange.location;
		}
		
		CFRange cfRange = CFRangeMake(_requestedStringRange.location, _requestedStringRange.length);
		_framesetter = layouter.framesetter;
		
		if (_framesetter)
		{
			CFRetain(_framesetter);
			
			CGMutablePathRef path = CGPathCreateMutable();
			CGPathAddRect(path, NULL, frame);
			
			_textFrame = CTFramesetterCreateFrame(_framesetter, cfRange, path, NULL);
			
			CGPathRelease(path);
		}
		else
		{
			// Strange, should have gotten a valid framesetter
			return nil;
		}
		
		_justifyRatio = 0.6f;
	}
	
	return self;
}

// makes a frame for the entire attributed string of the layouter
- (id)initWithFrame:(CGRect)frame layouter:(DTCoreTextLayouter *)layouter
{
	return [self initWithFrame:frame layouter:layouter range:NSMakeRange(0, 0)];
}

- (void)dealloc
{
	if (self.textFrameBornQueue) {
		dispatch_sync(self.textFrameBornQueue, ^{
			if (_textFrame)
			{
				CFRelease(_textFrame);
			}
			
			if (_framesetter)
			{
				CFRelease(_framesetter);
			}
		});
	}
	else {
		if (_textFrame)
		{
			CFRelease(_textFrame);
		}
		
		if (_framesetter)
		{
			CFRelease(_framesetter);
		}
	}
}

#ifndef COVERAGE
// exclude method from coverage testing

- (NSString *)description
{
	return [self.lines description];
}

#endif

#pragma mark - Positioning Lines

- (CGPoint)_algorithmLegacy_BaselineOriginToPositionLine:(DTCoreTextLayoutLine *)line afterLine:(DTCoreTextLayoutLine *)previousLine
{
	CGPoint lineOrigin = previousLine.baselineOrigin;
	
	NSInteger lineStartIndex = line.stringRange.location;
	
	CTParagraphStyleRef lineParagraphStyle = (__bridge CTParagraphStyleRef)[_attributedStringFragment
																			attribute:(id)kCTParagraphStyleAttributeName
																			atIndex:lineStartIndex effectiveRange:NULL];
	
	//Meet the first line in this frame
	if (!previousLine)
	{
		// The first line may or may not be the start of paragraph. It depends on the the range passing to
		// - (DTCoreTextLayoutFrame *)layoutFrameWithRect:(CGRect)frame range:(NSRange)range;
		// So Check it in a safe way:
		if ([self isLineFirstInParagraph:line])
		{
			
			CGFloat paraSpacingBefore = 0;
			
			if (CTParagraphStyleGetValueForSpecifier(lineParagraphStyle, kCTParagraphStyleSpecifierParagraphSpacingBefore, sizeof(paraSpacingBefore), &paraSpacingBefore))
			{
				lineOrigin.y += paraSpacingBefore;
			}
			
			// preserve own baseline x
			lineOrigin.x = line.baselineOrigin.x;
			
			// origins are rounded
			lineOrigin.y = ceil(lineOrigin.y);
			
			return lineOrigin;
			
		}
		
	}
	
	// get line height in px if it is specified for this line
	CGFloat lineHeight = 0;
	CGFloat minLineHeight = 0;
	CGFloat maxLineHeight = 0;
	BOOL usesForcedLineHeight = NO;
	
	CGFloat usedLeading = line.leading;
	
	if (usedLeading == 0.0f)
	{
		// font has no leading, so we fake one (e.g. Helvetica)
		CGFloat tmpHeight = line.ascent + line.descent;
		usedLeading = ceil(0.2f * tmpHeight);
		
		if (usedLeading>20)
		{
			// we have a large image increasing the ascender too much for this calc to work
			usedLeading = 0;
		}
	}
	else
	{
		// make sure that we don't have less than 10% of line height as leading
		usedLeading = ceil(MAX((line.ascent + line.descent)*0.1f, usedLeading));
	}
	
	if (CTParagraphStyleGetValueForSpecifier(lineParagraphStyle, kCTParagraphStyleSpecifierMinimumLineHeight, sizeof(minLineHeight), &minLineHeight))
	{
		usesForcedLineHeight = YES;
		
		if (lineHeight<minLineHeight)
		{
			lineHeight = minLineHeight;
		}
	}
	
	// is absolute line height set?
	if (lineHeight==0)
	{
		lineHeight = line.descent + line.ascent + usedLeading;
	}
	
	if ([self isLineLastInParagraph:previousLine])
	{
		// need to get paragraph spacing
		CTParagraphStyleRef previousLineParagraphStyle = (__bridge CTParagraphStyleRef)[_attributedStringFragment
																						attribute:(id)kCTParagraphStyleAttributeName
																						atIndex:previousLine.stringRange.location effectiveRange:NULL];
		
		// Paragraph spacings are paragraph styles and should not be multiplied by kCTParagraphStyleSpecifierLineHeightMultiple
		// So directly add them to lineOrigin.y
		CGFloat paraSpacing;
		
		if (CTParagraphStyleGetValueForSpecifier(previousLineParagraphStyle, kCTParagraphStyleSpecifierParagraphSpacing, sizeof(paraSpacing), &paraSpacing))
		{
			lineOrigin.y += paraSpacing;
		}
		
		CGFloat paraSpacingBefore;
		
		if (CTParagraphStyleGetValueForSpecifier(lineParagraphStyle, kCTParagraphStyleSpecifierParagraphSpacingBefore, sizeof(paraSpacingBefore), &paraSpacingBefore))
		{
			lineOrigin.y += paraSpacingBefore;
		}
	}
	
	CGFloat lineHeightMultiplier = 0;
	
	if (CTParagraphStyleGetValueForSpecifier(lineParagraphStyle, kCTParagraphStyleSpecifierLineHeightMultiple, sizeof(lineHeightMultiplier), &lineHeightMultiplier))
	{
		if (lineHeightMultiplier>0.0f)
		{
			lineHeight *= lineHeightMultiplier;
		}
	}
	
	if (CTParagraphStyleGetValueForSpecifier(lineParagraphStyle, kCTParagraphStyleSpecifierMaximumLineHeight, sizeof(maxLineHeight), &maxLineHeight))
	{
		if (maxLineHeight>0 && lineHeight>maxLineHeight)
		{
			lineHeight = maxLineHeight;
		}
	}
	
	lineOrigin.y += lineHeight;
	
	// preserve own baseline x
	lineOrigin.x = line.baselineOrigin.x;
	
	// prevent overlap of a line with small font size with line before it
	if (!usesForcedLineHeight)
	{
		// only if there IS a line before it AND the line height is not fixed
		CGFloat previousLineBottom = CGRectGetMaxY(previousLine.frame);
		
		if (lineOrigin.y - line.ascent < previousLineBottom)
		{
			// move baseline origin down far enough
			lineOrigin.y = previousLineBottom + line.ascent;
		}
	}
	
	// origins are rounded
	lineOrigin.y = ceil(lineOrigin.y);
	
	return lineOrigin;
}

// determines the "half leading"
- (CGFloat)_algorithmWebKit_halfLeadingOfLine:(DTCoreTextLayoutLine *)line
{
	CGFloat maxFontSize = [line lineHeight];
	
	DTCoreTextParagraphStyle *paragraphStyle = [line paragraphStyle];
	
	if (paragraphStyle.minimumLineHeight != 0 && paragraphStyle.minimumLineHeight > maxFontSize)
	{
		maxFontSize = paragraphStyle.minimumLineHeight;
	}
	
	if (paragraphStyle.maximumLineHeight != 0 && paragraphStyle.maximumLineHeight < maxFontSize)
	{
		maxFontSize = paragraphStyle.maximumLineHeight;
	}
	
	CGFloat leading;
	
	if (paragraphStyle.lineHeightMultiple > 0)
	{
		leading = maxFontSize * paragraphStyle.lineHeightMultiple;
	}
	else
	{
		// reasonable "normal"
		leading = maxFontSize * 1.1f;
	}
	
	// subtract inline box height
	CGFloat inlineBoxHeight = line.ascent + line.descent;
	
	return (leading - inlineBoxHeight)/2.0f;
}


- (CGPoint)_algorithmWebKit_BaselineOriginToPositionLine:(DTCoreTextLayoutLine *)line afterLine:(DTCoreTextLayoutLine *)previousLine
{
	CGPoint baselineOrigin = previousLine.baselineOrigin;
	
	if (previousLine)
	{
		baselineOrigin.y = CGRectGetMaxY(previousLine.frame);
		
		CGFloat halfLeadingFromText = [self _algorithmWebKit_halfLeadingOfLine:previousLine];
		
		if (previousLine.attachments)
		{
			// only add half leading if there are no attachments, this prevents line from being shifted up due to negative half leading
			if (halfLeadingFromText>0)
			{
				baselineOrigin.y += halfLeadingFromText;
			}
		}
		else
		{
			baselineOrigin.y += halfLeadingFromText;
		}
		
		// add previous line's after paragraph spacing
		if ([self isLineLastInParagraph:previousLine])
		{
			DTCoreTextParagraphStyle *paragraphStyle = [previousLine paragraphStyle];
			baselineOrigin.y += paragraphStyle.paragraphSpacing;
		}
	}
	else
	{
		// first line in frame
		baselineOrigin = _frame.origin;
	}
	
	baselineOrigin.y += line.ascent;
	
	CGFloat halfLeadingFromText = [self _algorithmWebKit_halfLeadingOfLine:line];
	
	if (line.attachments)
	{
		// only add half leading if there are no attachments, this prevents line from being shifted up due to negative half leading
		if (halfLeadingFromText>0)
		{
			baselineOrigin.y += halfLeadingFromText;
		}
	}
	else
	{
		baselineOrigin.y += halfLeadingFromText;
	}
	
	DTCoreTextParagraphStyle *paragraphStyle = [line paragraphStyle];
	
	// add current line's before paragraph spacing
	if ([self isLineFirstInParagraph:line])
	{
		baselineOrigin.y += paragraphStyle.paragraphSpacingBefore;
	}
	
	// add padding for closed text blocks
	for (DTTextBlock *previousTextBlock in previousLine.textBlocks)
	{
		if (![line.textBlocks containsObject:previousTextBlock])
		{
			baselineOrigin.y  += previousTextBlock.padding.bottom;
		}
	}
	
	// add padding for newly opened text blocks
	for (DTTextBlock *currentTextBlock in line.textBlocks)
	{
		if (![previousLine.textBlocks containsObject:currentTextBlock])
		{
			baselineOrigin.y  += currentTextBlock.padding.top;
		}
	}
	
	// origins are rounded
	baselineOrigin.y = ceil(baselineOrigin.y);
	
	return baselineOrigin;
}


- (CGPoint)baselineOriginToPositionLine:(DTCoreTextLayoutLine *)line afterLine:(DTCoreTextLayoutLine *)previousLine options:(DTCoreTextLayoutFrameLinePositioningOptions)options
{
	if (options & DTCoreTextLayoutFrameLinePositioningOptionAlgorithmWebKit)
	{
		return [self _algorithmWebKit_BaselineOriginToPositionLine:line afterLine:previousLine];
	}
	
	if (options & DTCoreTextLayoutFrameLinePositioningOptionAlgorithmLegacy)
	{
		return [self _algorithmLegacy_BaselineOriginToPositionLine:line afterLine:previousLine];
	}
	
	return CGPointZero;
}

// deprecated
- (CGPoint)baselineOriginToPositionLine:(DTCoreTextLayoutLine *)line afterLine:(DTCoreTextLayoutLine *)previousLine
{
	return [self baselineOriginToPositionLine:line afterLine:previousLine options:DTCoreTextLayoutFrameLinePositioningOptionAlgorithmWebKit];
}

#pragma mark - Building the Lines

-(CTLineRef) trimedLastLineWithinRange:(NSRange)lineRange inWidth:(CGFloat) width trimedCount:(NSInteger*)trimdCount;
{
    if (lineRange.length > 0) {
        
        CTTypesetterRef typesetter = CTFramesetterGetTypesetter(_framesetter);
        if (typesetter) {
            NSInteger oldLength = lineRange.length;
            lineRange.length = CTTypesetterSuggestLineBreak(typesetter, lineRange.location, width*0.4f);
            if (trimdCount) {
                *trimdCount = oldLength - lineRange.length;
            }
            return CTTypesetterCreateLine(typesetter, CFRangeMake(lineRange.location, lineRange.length));
            
        }
    }
    return nil;
}

/*
 Builds the array of lines with the internal typesetter of our framesetter. No need to correct line origins in this case because they are placed correctly in the first place.
 */
- (void)_buildLinesWithTypesetterForTeaser
{
	// framesetter keeps internal reference, no need to retain
	CTTypesetterRef typesetter = CTFramesetterGetTypesetter(_framesetter);
	
	NSMutableArray *typesetLines = [NSMutableArray array];
	
	CGPoint lineOrigin = _frame.origin;
	
	DTCoreTextLayoutLine *previousLine = nil;
	
	// need the paragraph ranges to know if a line is at the beginning of paragraph
	NSMutableArray *paragraphRanges = [[self paragraphRanges] mutableCopy];
	
	NSRange currentParagraphRange = [[paragraphRanges objectAtIndex:0] rangeValue];
	
	// we start out in the requested range, length will be set by the suggested line break function
	NSRange lineRange = _requestedStringRange;
	
	// maximum values for abort of loop
	CGFloat maxY = CGRectGetMaxY(_frame);
	NSUInteger maxIndex = NSMaxRange(_requestedStringRange);
	NSUInteger fittingLength = 0;
	
	typedef struct
	{
		CGFloat ascent;
		CGFloat descent;
		CGFloat width;
		CGFloat leading;
		CGFloat trailingWhitespaceWidth;
	} lineMetrics;
	
	typedef struct
	{
		CGFloat paragraphSpacingBefore;
		CGFloat paragraphSpacing;
		CGFloat lineHeightMultiplier;
		DTHTMLElementFloatStyle floatStyle;
		NSInteger displayStyle;
		CGRect	frame; // only valid if floatStyle != DTHTMLElementFloatStyleNone.
	} paragraphMetrics;
	
	paragraphMetrics currentParaMetrics = {0,0,0, DTHTMLElementFloatStyleNone, 0, CGRectZero};
	paragraphMetrics previousParaMetrics = {0,0,0, DTHTMLElementFloatStyleNone, 0, CGRectZero};
	
	lineMetrics currentLineMetrics;
	
	DTTextBlock *currentTextBlock = nil;
	DTTextBlock *previousTextBlock = nil;
	
	BOOL outOfPreviousFloatingFrameAffect = YES;
	CGRect previousFloatFrame = CGRectZero;
	DTHTMLElementFloatStyle previousFloatStyle = DTHTMLElementFloatStyleNone;
	
	DTCoreTextLayoutLine* bottomLine;
	CGFloat yOriginBeforeJumpToBottom = 0;
	
	do
	{
		while (lineRange.location >= NSMaxRange(currentParagraphRange))
		{
			// we are outside of this paragraph, so we go to the next
			[paragraphRanges removeObjectAtIndex:0];
			
			currentParagraphRange = [[paragraphRanges objectAtIndex:0] rangeValue];
		}
		
		BOOL isAtBeginOfParagraph = (currentParagraphRange.location == lineRange.location);
		BOOL bottomAttributeFound = NO;
		if (isAtBeginOfParagraph) {
			bottomAttributeFound = [[_attributedStringFragment attribute:DTBottomOrTopStyleAttribute atIndex:lineRange.location effectiveRange:NULL] boolValue];
		}
		
		CGFloat leftWidthUsed = 0;
		
		// get the paragraph style at this index
		CTParagraphStyleRef paragraphStyle = (__bridge CTParagraphStyleRef)[_attributedStringFragment attribute:(id)kCTParagraphStyleAttributeName atIndex:lineRange.location effectiveRange:NULL];
		
		currentTextBlock = [[_attributedStringFragment attribute:DTTextBlocksAttribute atIndex:lineRange.location effectiveRange:NULL] lastObject];
		
		if (isAtBeginOfParagraph && previousTextBlock && previousParaMetrics.floatStyle != DTHTMLElementFloatStyleNone)
		{
			previousParaMetrics.frame.size.height += previousTextBlock.padding.bottom + previousTextBlock.padding.top;
		}
		
		if (previousTextBlock != currentTextBlock)
		{
			lineOrigin.y += previousTextBlock.padding.bottom;
			lineOrigin.y += currentTextBlock.padding.top;
			
			previousTextBlock = currentTextBlock;
		}
		
		if (bottomAttributeFound) {
			yOriginBeforeJumpToBottom = lineOrigin.y;
		}
		
		CGFloat firstLineIndent = 0;
		
		if (isAtBeginOfParagraph)
		{
			CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierFirstLineHeadIndent, sizeof(firstLineIndent), &firstLineIndent);
			
			// save prev paragraph
			previousParaMetrics = currentParaMetrics;
			if (previousParaMetrics.floatStyle != DTHTMLElementFloatStyleNone)
			{
				// We've just layouted a floating paragraph, so record it
				previousFloatFrame = previousParaMetrics.frame;
				previousFloatStyle = previousParaMetrics.floatStyle;
				outOfPreviousFloatingFrameAffect = NO;
			}
			// Save the paragraphSpacingBefore to currentParaMetrics. This should be done after saving previousParaMetrics.
			CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierParagraphSpacingBefore, sizeof(currentParaMetrics.paragraphSpacingBefore), &currentParaMetrics.paragraphSpacingBefore);
			CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierLineBoundsOptions, sizeof(currentParaMetrics.displayStyle), &currentParaMetrics.displayStyle);
			
			NSNumber* currentFloatSytle = [_attributedStringFragment attribute:DTFloatStyleAttribute atIndex:lineRange.location effectiveRange:NULL];
			if ((currentFloatSytle && currentFloatSytle.intValue != DTHTMLElementFloatStyleNone))
			{
				currentParaMetrics.floatStyle = (DTHTMLElementFloatStyle)currentFloatSytle.intValue;
				// a new floating paragraphs begins, we doesn't support continues floating paragraphs, so invalidate previous floating and jump out
				lineOrigin.y = MAX(lineOrigin.y, CGRectGetMaxY(previousFloatFrame));
				outOfPreviousFloatingFrameAffect = YES;
				previousFloatStyle = DTHTMLElementFloatStyleNone;
				previousFloatFrame = CGRectZero;
			}
			else
			{
				currentParaMetrics.floatStyle = DTHTMLElementFloatStyleNone;
				
				if (previousParaMetrics.floatStyle != DTHTMLElementFloatStyleNone)
				{
					// we're transiting from an floating paragraph to an non-floating paragraph, so reset the lineOrigin.y to minY of previous floating rect to jump in
					lineOrigin.y = CGRectGetMinY(previousFloatFrame);
					outOfPreviousFloatingFrameAffect = NO;
				}
			}
			
			// All floating related modification to lineOrigin.y is done in this block, here after lineOrigin.y can be used as normal, only lineOrigin.x and line.width need to be conserned
			
		}
		
		// Calculate availableLineWidth and lineOrigin.x
		CGFloat availableLineWidth = 0;
		{
			
			if (previousFloatStyle == DTHTMLElementFloatStyleLeft && !outOfPreviousFloatingFrameAffect)
			{
				// Under the effect of left floating
				lineOrigin.x = CGRectGetMaxX(previousFloatFrame) + firstLineIndent + currentTextBlock.padding.left;
				availableLineWidth = CGRectGetMaxX(_frame) - lineOrigin.x - currentTextBlock.padding.right;
				
			}
			else if (previousFloatStyle == DTHTMLElementFloatStyleRight && !outOfPreviousFloatingFrameAffect)
			{
				// Under the effect of right floating
				lineOrigin.x = _frame.origin.x + firstLineIndent + currentTextBlock.padding.left;
				availableLineWidth = CGRectGetMinX(previousFloatFrame) - lineOrigin.x - currentTextBlock.padding.right;
			}
			else if (currentParaMetrics.floatStyle == DTHTMLElementFloatStyleLeft)
			{
				// Left floating itself
				lineOrigin.x = _frame.origin.x + firstLineIndent + currentTextBlock.padding.left;
				availableLineWidth = CGRectGetMaxX(_frame) - lineOrigin.x - currentTextBlock.padding.right;
				
			}
			else if (currentParaMetrics.floatStyle == DTHTMLElementFloatStyleRight)
			{
				if (isAtBeginOfParagraph)
				{
					// Right floating itself
					availableLineWidth = _frame.size.width - firstLineIndent - currentTextBlock.padding.left - currentTextBlock.padding.right;
				}
				else
				{
					lineOrigin.x = currentParaMetrics.frame.origin.x + currentTextBlock.padding.left;;
					availableLineWidth = CGRectGetMaxX(_frame) - lineOrigin.x - currentTextBlock.padding.right;
				}
			}
			else
			{
				// No floating stuff
				lineOrigin.x = _frame.origin.x + firstLineIndent + currentTextBlock.padding.left;
				availableLineWidth = CGRectGetMaxX(_frame) - lineOrigin.x - currentTextBlock.padding.right;
			}
		}
		
		// find how many characters we get into this line
		lineRange.length = CTTypesetterSuggestLineBreak(typesetter, lineRange.location, availableLineWidth);
		
		
		if (NSMaxRange(lineRange) > maxIndex)
		{
			// only layout as much as was requested
			lineRange.length = maxIndex - lineRange.location;
		}
		
		if (NSMaxRange(lineRange) == NSMaxRange(currentParagraphRange))
		{
			// at end of paragraph, record the spacing
			CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierParagraphSpacing, sizeof(currentParaMetrics.paragraphSpacing), &currentParaMetrics.paragraphSpacing);
		}
		
		// create a line to fit
		CTLineRef line = NULL;
		DTTextAttachment* attachment = [_attributedStringFragment attribute:NSAttachmentAttributeName atIndex:lineRange.location effectiveRange:NULL];
		CGFloat attachmentWidth = attachment.displaySize.width;
		if (attachmentWidth >= availableLineWidth && !outOfPreviousFloatingFrameAffect) {
			// Jump out of prev floating frame.
			lineOrigin.x = _frame.origin.x + firstLineIndent + currentTextBlock.padding.left;
			lineOrigin.y = MAX(lineOrigin.y, CGRectGetMaxY(previousFloatFrame));
			outOfPreviousFloatingFrameAffect = YES;
			previousFloatStyle = DTHTMLElementFloatStyleNone;
			previousFloatFrame = CGRectZero;
		}
		if (attachment && attachment.wantSingleLine == YES) {
			line = CTTypesetterCreateLine(typesetter, CFRangeMake(lineRange.location, 1));
		}
		else{
			line = CTTypesetterCreateLine(typesetter, CFRangeMake(lineRange.location, lineRange.length));
		}
		
		// we need all metrics so get the at once
		currentLineMetrics.width = (CGFloat)CTLineGetTypographicBounds(line, &currentLineMetrics.ascent, &currentLineMetrics.descent, &currentLineMetrics.leading);
		currentLineMetrics.leading = 0;
		
		if (isAtBeginOfParagraph)
		{
			lineOrigin.y += previousParaMetrics.paragraphSpacing;
			lineOrigin.y += currentParaMetrics.paragraphSpacingBefore;
			
			// float attribute can only be applied to an entire paragraph, so the origin of this paragraph's floating rect can be calculated correctly now. firstLineIndent is not included.
			if (currentParaMetrics.floatStyle == DTHTMLElementFloatStyleLeft)
			{
				currentParaMetrics.frame.origin.x = _frame.origin.x;
				currentParaMetrics.frame.origin.y = lineOrigin.y;
				
				// if a float attribute is assigned to a text paragraph, we consider the first line's width to be the max width and set it to the paragraph's rect.width+padding
				currentParaMetrics.frame.size.width = currentTextBlock.padding.left + ceil(currentLineMetrics.width) + currentTextBlock.padding.right;
			}
			else if (currentParaMetrics.floatStyle == DTHTMLElementFloatStyleRight)
			{
				// if a float attribute is assigned to a text paragraph, we consider the first line's width to be the max width and set it to the paragraph's rect.width+padding
				currentParaMetrics.frame.size.width = currentTextBlock.padding.left + ceil(currentLineMetrics.width) + currentTextBlock.padding.right;
				currentParaMetrics.frame.origin.x = CGRectGetMaxX(_frame) - currentParaMetrics.frame.size.width;
				currentParaMetrics.frame.origin.y = lineOrigin.y;
				
				// always adjust lineOrigin.x if right floating && first line
				lineOrigin.x = CGRectGetMaxX(_frame) - currentTextBlock.padding.right - currentLineMetrics.width;
			}
		}
		
		// get line height in px if it is specified for this line
		CGFloat lineHeight = currentLineMetrics.descent + currentLineMetrics.ascent;
		CGFloat minLineHeight = 0;
		CGFloat maxLineHeight = 0;
		if (CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierMinimumLineHeight, sizeof(minLineHeight), &minLineHeight))
		{
			if (minLineHeight > 0 && lineHeight<minLineHeight)
			{
				lineHeight = minLineHeight;
			}
		}
		if (CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierLineHeightMultiple, sizeof(currentParaMetrics.lineHeightMultiplier), &currentParaMetrics.lineHeightMultiplier))
		{
			if (currentParaMetrics.lineHeightMultiplier>0.0f)
			{
				lineHeight *= currentParaMetrics.lineHeightMultiplier;
			}
		}
		
		if (CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierMaximumLineHeight, sizeof(maxLineHeight), &maxLineHeight))
		{
			if (maxLineHeight > 0 && lineHeight>maxLineHeight)
			{
				lineHeight = maxLineHeight;
			}
		}
		if (currentParaMetrics.floatStyle == DTHTMLElementFloatStyleNone && previousParaMetrics.floatStyle != DTHTMLElementFloatStyleNone && isAtBeginOfParagraph && !outOfPreviousFloatingFrameAffect)
		{
			// we're transiting from an floating paragraph to an non-floating paragraph, so reset the lineOrigin.y to minY of previous floating rect to jump in
			lineOrigin.y = CGRectGetMinY(previousFloatFrame);
			lineOrigin.y += currentLineMetrics.ascent;
		}
		else{
			lineOrigin.y += lineHeight;
		}
		
		if (bottomAttributeFound) {
			lineOrigin.y = ceil(maxY);
		}
		
		if (currentParaMetrics.floatStyle == DTHTMLElementFloatStyleNone) {
			// adjust lineOrigin based on paragraph text alignment
			CTTextAlignment textAlignment;
			
			if (!CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierAlignment, sizeof(textAlignment), &textAlignment))
			{
				textAlignment = kCTNaturalTextAlignment;
			}
			
			switch (textAlignment)
			{
				case kCTLeftTextAlignment:
				{
					lineOrigin.x = _frame.origin.x + leftWidthUsed;
					// nothing to do
					break;
				}
					
				case kCTNaturalTextAlignment:
				{
					// depends on the text direction
					CTWritingDirection baseWritingDirection;
					CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierBaseWritingDirection, sizeof(baseWritingDirection), &baseWritingDirection);
					
					if (baseWritingDirection != kCTWritingDirectionRightToLeft)
					{
						break;
					}
					
					// right alignment falls through
				}
					
				case kCTRightTextAlignment:
				{
					lineOrigin.x = _frame.origin.x + leftWidthUsed + (CGFloat)CTLineGetPenOffsetForFlush(line, 1.0, availableLineWidth);
					
					break;
				}
					
				case kCTCenterTextAlignment:
				{
					lineOrigin.x = _frame.origin.x + leftWidthUsed + (CGFloat)CTLineGetPenOffsetForFlush(line, 0.5, availableLineWidth);
					
					break;
				}
					
				case kCTJustifiedTextAlignment:
				{
					BOOL isAtEndOfParagraph    = (currentParagraphRange.location+currentParagraphRange.length <= lineRange.location+lineRange.length || 		// JTL 28/June/2012
												  [[_attributedStringFragment string] characterAtIndex:lineRange.location+lineRange.length-1]==0x2028);									// JTL 28/June/2012
					
					// only justify if not last line, not <br>, and if the line width is longer than 60% of the frame
					// avoids over-stretching
					if( !isAtEndOfParagraph && (currentLineMetrics.width > 0.60 * _frame.size.width) )
					{
						// create a justified line and replace the current one with it
						CTLineRef justifiedLine = CTLineCreateJustifiedLine(line, 1.0f, availableLineWidth);
						CFRelease(line);
						line = justifiedLine;
					}
					
					lineOrigin.x = _frame.origin.x + leftWidthUsed;
					
					break;
				}
			}
		}
		
		// update the rect height of this paragraph if it's floating
		if (currentParaMetrics.floatStyle != DTHTMLElementFloatStyleNone)
		{
			currentParaMetrics.frame.size.height = ceil(lineOrigin.y - currentParaMetrics.frame.origin.y);
		}
		else
		{
			if (previousFloatStyle != DTHTMLElementFloatStyleNone && lineOrigin.y > CGRectGetMaxY(previousFloatFrame))
			{
				outOfPreviousFloatingFrameAffect = YES;
				previousFloatStyle = DTHTMLElementFloatStyleNone;
				previousFloatFrame = CGRectZero;
			}
		}
		
		CGFloat lineBottom = lineOrigin.y + currentLineMetrics.descent;
		
		// abort layout if we left the configured frame
		if (lineBottom>maxY)
		{
			// doesn't fit any more
			BOOL canTrim = self.trimLastLine && previousLine && previousLine != bottomLine;
			if (canTrim) {
				NSInteger trimedCount = 0;
				CTLineRef trimedLastLine = [self trimedLastLineWithinRange:previousLine.stringRange inWidth:availableLineWidth trimedCount:&trimedCount];
				fittingLength -= trimedCount;
				DTCoreTextLayoutLine *newTrimedLine = [[DTCoreTextLayoutLine alloc] initWithLine:trimedLastLine];
				CFRelease(trimedLastLine);
				newTrimedLine.baselineOrigin = previousLine.baselineOrigin;
				[typesetLines removeObject:previousLine];
				[typesetLines addObject:newTrimedLine];
			}
			CFRelease(line);
			break;
		}
		
		// wrap it
		DTCoreTextLayoutLine *newLine = [[DTCoreTextLayoutLine alloc] initWithLine:line];
		CFRelease(line);
		
		// baseline origin is rounded
		lineOrigin.y = ceil(lineOrigin.y);
		CGPoint fixedOrigin = lineOrigin;
		if ((currentParaMetrics.floatStyle != DTHTMLElementFloatStyleNone))
		{
			fixedOrigin.y += 4;
		}
		newLine.baselineOrigin = fixedOrigin;
		
		fittingLength += lineRange.length;
		
		lineRange.location += lineRange.length;
		
		if (bottomAttributeFound) {
			bottomLine = newLine;
			lineOrigin.y = yOriginBeforeJumpToBottom;
			maxY -= lineHeight + currentParaMetrics.paragraphSpacingBefore;
		}
		else{
			[typesetLines addObject:newLine];
			previousLine = newLine;
		}
		
	}
	while (lineRange.location < maxIndex);
	
	if (bottomLine) {
		DTCoreTextLayoutLine *lastLine = typesetLines.lastObject;
		if (lastLine) {
			CGFloat usedMaxY = ceil((CGRectGetMaxY(lastLine.frame) - _frame.origin.y + 1.5f + currentTextBlock.padding.bottom));
			CGFloat deltaHeight = maxY - usedMaxY;
			bottomLine.baselineOrigin = CGPointMake(bottomLine.baselineOrigin.x, bottomLine.baselineOrigin.y - deltaHeight+2);
		}
	}
	
	if (bottomLine) {
		[typesetLines addObject:bottomLine];
	}
	
	_lines = typesetLines;
	
	if (![_lines count])
	{
		// no lines fit
		_stringRange = NSMakeRange(0, 0);
		
		return;
	}
	
	// now we know how many characters fit
	_stringRange.location = _requestedStringRange.location;
	_stringRange.length = fittingLength;
	
	// at this point we can correct the frame if it is open-ended
	if (_frame.size.height == CGFLOAT_HEIGHT_UNKNOWN)
	{
		// actual frame is spanned between first and last lines
		DTCoreTextLayoutLine *lastLine = [_lines lastObject];
		
		_frame.size.height = ceil((CGRectGetMaxY(lastLine.frame) - _frame.origin.y + 1.5f + currentTextBlock.padding.bottom));
		
		// need to add bottom padding if in text block
	}
}

/*
 Builds the array of lines with the internal typesetter of our framesetter. No need to correct line origins in this case because they are placed correctly in the first place. This version supports text boxes.
 */
- (void)_buildLinesWithTypesetter
{
	// framesetter keeps internal reference, no need to retain
	CTTypesetterRef typesetter = CTFramesetterGetTypesetter(_framesetter);
	
	NSMutableArray *typesetLines = [NSMutableArray array];
	
	DTCoreTextLayoutLine *previousLine = nil;
	
	// need the paragraph ranges to know if a line is at the beginning of paragraph
	NSMutableArray *paragraphRanges = [[self paragraphRanges] mutableCopy];
	
	NSRange currentParagraphRange = [[paragraphRanges objectAtIndex:0] rangeValue];
	
	// we start out in the requested range, length will be set by the suggested line break function
	NSRange lineRange = _requestedStringRange;
	
	// maximum values for abort of loop
	CGFloat maxY = CGRectGetMaxY(_frame);
	NSUInteger maxIndex = NSMaxRange(_requestedStringRange);
	NSUInteger fittingLength = 0;
	BOOL shouldTruncateLine = NO;
	
	do  // for each line
	{
		while (lineRange.location >= (currentParagraphRange.location+currentParagraphRange.length))
		{
			// we are outside of this paragraph, so we go to the next
			[paragraphRanges removeObjectAtIndex:0];
			
			currentParagraphRange = [[paragraphRanges objectAtIndex:0] rangeValue];
		}
		
		BOOL isAtBeginOfParagraph = (currentParagraphRange.location == lineRange.location);
		
		if (isAtBeginOfParagraph && currentParagraphRange.length <= 2) {
			NSString* subString = [[[self attributedStringFragment] string] substringWithRange:currentParagraphRange];
			if ([subString isEqualToString:@"\n"]) {
				lineRange.length = currentParagraphRange.length;
				fittingLength += lineRange.length;
				lineRange.location += lineRange.length;
				continue;
			}
			
		}
		
		CGFloat headIndent = 0;
		CGFloat tailIndent = 0;
		BOOL floatTopRight = NO;
		
		// get the paragraph style at this index
		CTParagraphStyleRef paragraphStyle = (__bridge CTParagraphStyleRef)[_attributedStringFragment attribute:(id)kCTParagraphStyleAttributeName atIndex:lineRange.location effectiveRange:NULL];
		id floatTopRightValue = [_attributedStringFragment attribute:DTFloatTopRightAttribute atIndex:lineRange.location effectiveRange:NULL];
		if (floatTopRightValue) {
			floatTopRight = YES;
		}
		if (isAtBeginOfParagraph)
		{
			CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierFirstLineHeadIndent, sizeof(headIndent), &headIndent);
		}
		else
		{
			CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierHeadIndent, sizeof(headIndent), &headIndent);
		}
		
		CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierTailIndent, sizeof(tailIndent), &tailIndent);
		
		// add left padding to offset
		CGFloat lineOriginX;
		CGFloat availableSpace;
		
		NSArray *textBlocks = [_attributedStringFragment attribute:DTTextBlocksAttribute atIndex:lineRange.location effectiveRange:NULL];
		CGFloat totalLeftPadding = 0;
		CGFloat totalRightPadding = 0;
		
		for (DTTextBlock *oneTextBlock in textBlocks)
		{
			totalLeftPadding += oneTextBlock.padding.left;
			totalRightPadding += oneTextBlock.padding.right;
		}
		
		if (tailIndent<=0)
		{
			// negative tail indent is measured from trailing margin (we assume LTR here)
			availableSpace = _frame.size.width - headIndent - totalRightPadding + tailIndent - totalLeftPadding;
		}
		else
		{
			availableSpace = tailIndent - headIndent - totalLeftPadding - totalRightPadding;
		}
		
		if (floatTopRight) {
			availableSpace = 10000.0f;
		}
		
		
		CGFloat offset = totalLeftPadding;
		
		// if first character is a tab, then it is positioned without the indentation
		if (![[[_attributedStringFragment string] substringWithRange:NSMakeRange(lineRange.location, 1)] isEqualToString:@"\t"])
		{
			offset += headIndent;
		}
		
		// find how many characters we get into this line
		lineRange.length = CTTypesetterSuggestLineBreak(typesetter, lineRange.location, availableSpace);
		
		if (NSMaxRange(lineRange) > maxIndex)
		{
			// only layout as much as was requested
			lineRange.length = maxIndex - lineRange.location;
		}
		
		
		// determine whether this is a normal line or if it should be truncated
		shouldTruncateLine = ((self.numberOfLines>0 && [typesetLines count]+1==self.numberOfLines) || (_numberLinesFitInFrame>0 && _numberLinesFitInFrame==[typesetLines count]+1));
		
		CTLineRef line;
		BOOL isHyphenatedString = NO;
		
		if (!shouldTruncateLine)
		{
			static const unichar softHypen = 0x00AD;
			NSString *lineString = [[_attributedStringFragment attributedSubstringFromRange:lineRange] string];
			unichar lastChar = [lineString characterAtIndex:[lineString length] - 1];
			if (softHypen == lastChar)
			{
				NSMutableAttributedString *hyphenatedString = [[_attributedStringFragment attributedSubstringFromRange:lineRange] mutableCopy];
				NSRange replaceRange = NSMakeRange(hyphenatedString.length - 1, 1);
				[hyphenatedString replaceCharactersInRange:replaceRange withString:@"-"];
				line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)hyphenatedString);
				isHyphenatedString = YES;
			}
			else
			{
				// create a line to fit
				line = CTTypesetterCreateLine(typesetter, CFRangeMake(lineRange.location, lineRange.length));
			}
		}
		else
		{
			// extend the line to the end of the current paragraph
			// if we extend to the entire to the entire text range
			// it is possible to pull lines up from paragraphs below us
			NSRange oldLineRange = lineRange;
			lineRange.length = NSMaxRange(currentParagraphRange)-lineRange.location;
			CTLineRef baseLine = CTTypesetterCreateLine(typesetter, CFRangeMake(lineRange.location, lineRange.length));
			
			// convert lineBreakMode to CoreText type
			CTLineTruncationType truncationType = DTCTLineTruncationTypeFromNSLineBreakMode(self.lineBreakMode);
			
			// prepare truncation string
			NSAttributedString * attribStr = self.truncationString;
			if(attribStr == nil)
			{
				NSRange range;
				NSInteger index = oldLineRange.location;
				if (truncationType == kCTLineTruncationEnd)
				{
					index += (oldLineRange.length > 0 ? oldLineRange.length - 1 : 0);
				}
				else if (truncationType == kCTLineTruncationMiddle)
				{
					index += (oldLineRange.length > 1 ? (oldLineRange.length/2.0 - 1) : 0);
				}
				NSDictionary * attributes = [_attributedStringFragment attributesAtIndex:index effectiveRange:&range];
				attribStr = [[NSAttributedString alloc] initWithString:@"…" attributes:attributes];
			}
			
			CTLineRef elipsisLineRef = CTLineCreateWithAttributedString((__bridge  CFAttributedStringRef)(attribStr));
			
			// create the truncated line
			line = CTLineCreateTruncatedLine(baseLine, availableSpace, truncationType, elipsisLineRef);
            
            // check if truncation occurred
            BOOL truncationOccured = !areLinesEqual(baseLine, line);
            // if yes check was it before the end of the current paragraph or after
            NSUInteger endOfParagraphIndex = NSMaxRange(currentParagraphRange);
            // this works only for truncation at the end
            if (truncationType == kCTLineTruncationEnd)
            {
                if (truncationOccured)
                {
                    CFIndex truncationIndex = getTruncationIndex(line, elipsisLineRef);
                    // if truncation occurred after the end of the paragraph
                    // move truncation token to the end of the paragraph
                    if (truncationIndex > endOfParagraphIndex)
                    {
                        NSAttributedString *subStr = [_attributedStringFragment attributedSubstringFromRange:NSMakeRange(lineRange.location, endOfParagraphIndex - lineRange.location - 1)];
                        NSMutableAttributedString *attrMutStr = [subStr mutableCopy];
                        [attrMutStr appendAttributedString:attribStr];
                        CFRelease(line);
                        line = CTLineCreateWithAttributedString((__bridge  CFAttributedStringRef)(attrMutStr));
                    }
                    // otherwise, everything is OK
                }
                else
                {
                    // if no truncation happened, force addition of
                    // the truncation token to the end of the paragraph
                    if (maxIndex != endOfParagraphIndex)
                    {
                        NSAttributedString *subStr = [_attributedStringFragment attributedSubstringFromRange:NSMakeRange(lineRange.location, endOfParagraphIndex - lineRange.location - 1)];
                        NSMutableAttributedString *attrMutStr = [subStr mutableCopy];
                        [attrMutStr appendAttributedString:attribStr];
                        CFRelease(line);
                        line = CTLineCreateWithAttributedString((__bridge  CFAttributedStringRef)(attrMutStr));
                    }
                }
            }
			
			// clean up
			CFRelease(baseLine);
			CFRelease(elipsisLineRef);
		}
		
		// we need all metrics so get the at once
		CGFloat currentLineWidth = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
		
		BOOL fullWidthNeeded = NO;

		if (currentLineWidth >= _frame.size.width+7 && UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
			fullWidthNeeded = YES;
		}
		
		// adjust lineOrigin based on paragraph text alignment
		CTTextAlignment textAlignment;
		
		if (!CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierAlignment, sizeof(textAlignment), &textAlignment))
		{
#if DTCORETEXT_SUPPORT_NS_ATTRIBUTES
			textAlignment = kCTTextAlignmentNatural;
#else
			textAlignment = kCTNaturalTextAlignment;
#endif
		}
		
		// determine writing direction
		BOOL isRTL = NO;
		CTWritingDirection baseWritingDirection;
		
		if (CTParagraphStyleGetValueForSpecifier(paragraphStyle, kCTParagraphStyleSpecifierBaseWritingDirection, sizeof(baseWritingDirection), &baseWritingDirection))
		{
			isRTL = (baseWritingDirection == kCTWritingDirectionRightToLeft);
		}
		else
		{
			baseWritingDirection = kCTWritingDirectionNatural;
		}
		
		switch (textAlignment)
		{
				
#if DTCORETEXT_SUPPORT_NS_ATTRIBUTES
			case kCTTextAlignmentLeft:
#else
			case kCTLeftTextAlignment:
#endif
			{
				lineOriginX = _frame.origin.x + offset;
				// nothing to do
				break;
			}
				
#if DTCORETEXT_SUPPORT_NS_ATTRIBUTES
			case kCTTextAlignmentNatural:
#else
			case kCTNaturalTextAlignment:
#endif
			{
				lineOriginX = _frame.origin.x + offset;
				
				if (baseWritingDirection != kCTWritingDirectionRightToLeft)
				{
					break;
				}
				
				// right alignment falls through
			}
				
#if DTCORETEXT_SUPPORT_NS_ATTRIBUTES
			case kCTTextAlignmentRight:
#else
			case kCTRightTextAlignment:
#endif
			{
				lineOriginX = _frame.origin.x + offset + (CGFloat)CTLineGetPenOffsetForFlush(line, 1.0, availableSpace);
				
				break;
			}
				
#if DTCORETEXT_SUPPORT_NS_ATTRIBUTES
			case kCTTextAlignmentCenter:
#else
			case kCTCenterTextAlignment:
#endif
			{
				lineOriginX = _frame.origin.x + offset + (CGFloat)CTLineGetPenOffsetForFlush(line, 0.5, availableSpace);
				
				break;
			}
				
#if DTCORETEXT_SUPPORT_NS_ATTRIBUTES
			case kCTTextAlignmentJustified:
#else
			case kCTJustifiedTextAlignment:
#endif
			{
				BOOL isAtEndOfParagraph  = (currentParagraphRange.location+currentParagraphRange.length <= lineRange.location+lineRange.length ||
											[[_attributedStringFragment string] characterAtIndex:lineRange.location+lineRange.length-1]==0x2028);
				
				// only justify if not last line, not <br>, and if the line width is longer than _justifyRatio of the frame
				// avoids over-stretching
				if( !isAtEndOfParagraph && (currentLineWidth > _justifyRatio * _frame.size.width) )
				{
					// create a justified line and replace the current one with it
					CTLineRef justifiedLine = CTLineCreateJustifiedLine(line, 1.0f, availableSpace);
					
					// CTLineCreateJustifiedLine sometimes fails if the line ends with 0x00AD (soft hyphen) and contains cyrillic chars
					if (justifiedLine)
					{
						CFRelease(line);
						line = justifiedLine;
					}
				}
				
				if (isRTL)
				{
					// align line with right margin
					lineOriginX = _frame.origin.x + offset + (CGFloat)CTLineGetPenOffsetForFlush(line, 1.0, availableSpace);
				}
				else
				{
					// align line with left margin
					lineOriginX = _frame.origin.x + offset;
				}
				
				break;
			}
		}
		
		if (!line)
		{
			continue;
		}
		
		// wrap it
		DTCoreTextLayoutLine *newLine = [[DTCoreTextLayoutLine alloc] initWithLine:line
															  stringLocationOffset:isHyphenatedString ? lineRange.location : 0];
		newLine.writingDirectionIsRightToLeft = isRTL;
		CFRelease(line);
		
		// determine position of line based on line before it
		
		CGPoint newLineBaselineOrigin = [self _algorithmWebKit_BaselineOriginToPositionLine:newLine afterLine:previousLine];
		newLineBaselineOrigin.x = fullWidthNeeded ? 0 : lineOriginX;
		newLine.baselineOrigin = newLineBaselineOrigin;
		
		if (floatTopRight) {
			
			DTCoreTextLayoutLine* floatBaseLine = [typesetLines objectAtIndex:typesetLines.count-2];
			CGPoint newLineBaselineOrigin = [self _algorithmWebKit_BaselineOriginToPositionLine:newLine afterLine:floatBaseLine];
			newLineBaselineOrigin.y += 2;
			newLineBaselineOrigin.x = CGRectGetMaxX(_frame) - currentLineWidth;
			newLine.baselineOrigin = newLineBaselineOrigin;
		}
		
		// abort layout if we left the configured frame
		CGFloat lineBottom = CGRectGetMaxY(newLine.frame);
		
		if (lineBottom>maxY)
		{
			if ([typesetLines count] && self.lineBreakMode)
			{
				_numberLinesFitInFrame = [typesetLines count];
				[self _buildLinesWithTypesetter];
				
				return;
			}
			else
			{
				// doesn't fit any more
				break;
			}
		}
		
		[typesetLines addObject:newLine];
		fittingLength += lineRange.length;
		
		lineRange.location += lineRange.length;
		previousLine = newLine;
	}
	while (lineRange.location < maxIndex && !shouldTruncateLine);
	
	_lines = typesetLines;
	
	if (![_lines count])
	{
		// no lines fit
		_stringRange = NSMakeRange(0, 0);
		
		return;
	}
	
	// now we know how many characters fit
	_stringRange.location = _requestedStringRange.location;
	_stringRange.length = fittingLength;
	
	// at this point we can correct the frame if it is open-ended
	if (_frame.size.height == CGFLOAT_HEIGHT_UNKNOWN)
	{
		DTCoreTextLayoutLine *lastLine = [_lines lastObject];
		
		CGFloat totalPadding = 0;
		
		for (DTTextBlock *oneTextBlock in lastLine.textBlocks)
		{
			totalPadding += oneTextBlock.padding.bottom;
		}
		
		// need to add bottom padding if in text block
		_additionalPaddingAtBottom = totalPadding;
	}
}

- (void)_buildLines
{
	// only build lines if frame is legal
	if (_frame.size.width<=0)
	{
		return;
	}
	
	if (self.usedAsTeaser) {
		[self _buildLinesWithTypesetterForTeaser];
	}
	else {
		// note: building line by line with typesetter
		[self _buildLinesWithTypesetter];
	}
	
	
	//[self _buildLinesWithStandardFramesetter];
}

- (NSArray *)lines
{
	if (!_lines)
	{
		[self _buildLines];
	}
	
	return _lines;
}

- (NSArray *)linesVisibleInRect:(CGRect)rect
{
	NSMutableArray *tmpArray = [NSMutableArray arrayWithCapacity:[self.lines count]];
	
	CGFloat minY = CGRectGetMinY(rect);
	CGFloat maxY = CGRectGetMaxY(rect);
	
	for (DTCoreTextLayoutLine *oneLine in self.lines)
	{
		CGRect lineFrame = oneLine.frame;
		
		// lines before the rect
		if (CGRectGetMaxY(lineFrame)<minY)
		{
			// skip
			continue;
		}
		
		// line is after the rect
		if (lineFrame.origin.y > maxY)
		{
			break;
		}
		
		// CGRectIntersectsRect returns false if the frame has 0 width, which
		// lines that consist only of line-breaks have. Set the min-width
		// to one to work-around.
		lineFrame.size.width = lineFrame.size.width>1?lineFrame.size.width:1;
		
		if (CGRectIntersectsRect(rect, lineFrame))
		{
			[tmpArray addObject:oneLine];
		}
	}
	
	return tmpArray;
}

- (NSArray *)linesContainedInRect:(CGRect)rect
{
	NSMutableArray *tmpArray = [NSMutableArray arrayWithCapacity:[self.lines count]];
	
	CGFloat minY = CGRectGetMinY(rect);
	CGFloat maxY = CGRectGetMaxY(rect);
	
	for (DTCoreTextLayoutLine *oneLine in self.lines)
	{
		CGRect lineFrame = oneLine.frame;
		
		// lines before the rect
		if (CGRectGetMaxY(lineFrame)<minY)
		{
			// skip
			continue;
		}
		
		// line is after the rect
		if (lineFrame.origin.y > maxY)
		{
			break;
		}
		
		if (CGRectContainsRect(rect, lineFrame))
		{
			[tmpArray addObject:oneLine];
		}
	}
	
	return tmpArray;
}


#pragma mark - Text Block Helpers

// determines the frame to use for a text block with a given effect range at a specific block level
- (CGRect)_blockFrameForEffectiveRange:(NSRange)effectiveRange level:(NSUInteger)level
{
	CGRect blockFrame;
	
    // we know extent of block, get frame
    DTCoreTextLayoutLine *firstBlockLine = [self lineContainingIndex:effectiveRange.location];
    DTCoreTextLayoutLine *lastBlockLine = [self lineContainingIndex:NSMaxRange(effectiveRange)-1];
    
    // start with frame spanned from these lines
    blockFrame.origin = firstBlockLine.frame.origin;
    blockFrame.origin.x = _frame.origin.x;
    blockFrame.size.width = _frame.size.width;
    blockFrame.size.height = CGRectGetMaxY(lastBlockLine.frame) - blockFrame.origin.y;
    
    // top paddings we get from first line
    for (NSInteger i = [firstBlockLine.textBlocks count]-1; i>=level;i--)
    {
        if (i<0)
        {
            break;
        }
        
        DTTextBlock *oneTextBlock = [firstBlockLine.textBlocks objectAtIndex:i];
        
        blockFrame.origin.y -= oneTextBlock.padding.top;
        blockFrame.size.height += oneTextBlock.padding.top;
    }
    
    // top padding we get from last line
    for (NSInteger i = [lastBlockLine.textBlocks count]-1; i>=level;i--)
    {
        if (i<0)
        {
            break;
        }
        
        DTTextBlock *oneTextBlock = [lastBlockLine.textBlocks objectAtIndex:i];
        
        blockFrame.size.height += oneTextBlock.padding.bottom;
    }
    
    // adjust left and right margins with block stack padding
    for (int i=0; i<level; i++)
    {
        DTTextBlock *textBlock = [firstBlockLine.textBlocks objectAtIndex:i];
        
        blockFrame.origin.x += textBlock.padding.left;
        blockFrame.size.width -= (textBlock.padding.left + textBlock.padding.right);
    }
	
	return CGRectIntegral(blockFrame);
}

// only enumerate blocks at a given level
// returns YES if there was at least one block enumerated at this level
- (BOOL)_enumerateTextBlocksAtLevel:(NSUInteger)level inRange:(NSRange)range usingBlock:(void (^)(DTTextBlock *textBlock, CGRect frame, NSRange effectiveRange, BOOL *stop))block
{
	NSParameterAssert(block);
	
	// synchronize globally to work around crashing bug in iOS accessing attributes concurrently in 2 separate layout frames, with separate attributed strings, but coming from same layouter.
	@synchronized((__bridge id)_framesetter)
	{
		NSUInteger length = [_attributedStringFragment length];
		NSUInteger index = range.location;
		
		BOOL foundBlockAtLevel = NO;
		
		while (index<NSMaxRange(range))
		{
			NSRange textBlocksArrayRange;
			NSArray *textBlocks = [_attributedStringFragment attribute:DTTextBlocksAttribute atIndex:index longestEffectiveRange:&textBlocksArrayRange inRange:range];
			
			index += textBlocksArrayRange.length;
			
			if ([textBlocks count] <= level)
			{
				// has no blocks at this level
				continue;
			}
			
			foundBlockAtLevel = YES;
			
			// find extent of outermost block
			DTTextBlock *blockAtLevelToHandle = [textBlocks objectAtIndex:level];
			
			NSUInteger searchIndex = NSMaxRange(textBlocksArrayRange);
			
			NSRange currentBlockEffectiveRange = textBlocksArrayRange;
			
			// search forward for actual end of block
			while (searchIndex < length && searchIndex < NSMaxRange(range))
			{
				NSRange laterBlocksRange;
				NSArray *laterBlocks = [_attributedStringFragment attribute:DTTextBlocksAttribute atIndex:searchIndex longestEffectiveRange:&laterBlocksRange inRange:range];
				
				if (![laterBlocks containsObject:blockAtLevelToHandle])
				{
					break;
				}
				
				currentBlockEffectiveRange = NSUnionRange(currentBlockEffectiveRange, laterBlocksRange);
				
				searchIndex = NSMaxRange(laterBlocksRange);
			}
			
			index = searchIndex;
			CGRect blockFrame = [self _blockFrameForEffectiveRange:currentBlockEffectiveRange level:level];
			
			BOOL shouldStop = NO;
			
			block(blockAtLevelToHandle, blockFrame, currentBlockEffectiveRange, &shouldStop);
			
			if (shouldStop)
			{
				return YES;
			}
		}
		
		return foundBlockAtLevel;
	}
}


// enumerates the text blocks in effect for a given string range
- (void)_enumerateTextBlocksInRange:(NSRange)range usingBlock:(void (^)(DTTextBlock *textBlock, CGRect frame, NSRange effectiveRange, BOOL *stop))block
{
	__block NSUInteger level = 0;
	
	while ([self _enumerateTextBlocksAtLevel:level inRange:range usingBlock:block])
	{
		level++;
	}
}

#pragma mark - Drawing

// draw and individual text block to a graphics context and frame
- (void)_drawTextBlock:(DTTextBlock *)textBlock inContext:(CGContextRef)context frame:(CGRect)frame
{
	BOOL shouldDrawStandardBackground = YES;
	if (_textBlockHandler)
	{
		_textBlockHandler(textBlock, frame, context, &shouldDrawStandardBackground);
	}
	
	// draw standard background if necessary
	if (shouldDrawStandardBackground)
	{
		if (textBlock.backgroundColor)
		{
			CGColorRef color = [textBlock.backgroundColor CGColor];
			CGContextSetFillColorWithColor(context, color);
			CGContextFillRect(context, frame);
		}
	}
	
	if (_DTCoreTextLayoutFramesShouldDrawDebugFrames)
	{
		CGContextSaveGState(context);
		
		// draw line bounds
		CGContextSetRGBStrokeColor(context, 0.5, 0, 0.5f, 1.0f);
		CGContextSetLineWidth(context, 2);
		CGContextStrokeRect(context, CGRectInset(frame, 2, 2));
		
		CGContextRestoreGState(context);
	}
}

// draws the text blocks that should be visible within the mentioned range and inside the clipping rect of the context
- (void)_drawTextBlocksInContext:(CGContextRef)context inRange:(NSRange)range
{
	CGRect clipRect = CGContextGetClipBoundingBox(context);
	
	[self _enumerateTextBlocksInRange:range usingBlock:^(DTTextBlock *textBlock, CGRect frame, NSRange effectiveRange, BOOL *stop) {
		
		CGRect visiblePart = CGRectIntersection(frame, clipRect);
		
		// do not draw boxes which are not in the current clip rect
		if (!CGRectIsInfinite(visiblePart))
		{
			[self _drawTextBlock:textBlock inContext:context frame:frame];
		}
	}];
}

- (void)_setShadowInContext:(CGContextRef)context fromDictionary:(NSDictionary *)dictionary additionalOffset:(CGSize)additionalOffset
{
	DTColor *color = [dictionary objectForKey:@"Color"];
	CGSize offset = [[dictionary objectForKey:@"Offset"] CGSizeValue];
	CGFloat blur = [[dictionary objectForKey:@"Blur"] floatValue];
	
	// add extra offset
	offset.width += additionalOffset.width;
	offset.height += additionalOffset.height;
	
	CGFloat scaleFactor = 1.0;
	
#if TARGET_OS_IPHONE
	if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)])
	{
		scaleFactor = [[UIScreen mainScreen] scale];
	}
#endif
	
	
	// workaround for scale 1: strangely offset (1,1) with blur 0 does not draw any shadow, (1.01,1.01) does
	if (scaleFactor==1.0)
	{
		if (fabs(offset.width)==1.0)
		{
			offset.width *= 1.50;
		}
		
		if (fabs(offset.height)==1.0)
		{
			offset.height *= 1.50;
		}
	}
	
	CGContextSetShadowWithColor(context, offset, blur, color.CGColor);
}

// draws the HR represented by the layout line
- (void)_drawHorizontalRuleFromLine:(DTCoreTextLayoutLine *)line inContext:(CGContextRef)context
{
	// HR has only a single glyph run with a \n, but that has all the attributes
	DTCoreTextGlyphRun *oneRun = [line.glyphRuns lastObject];
	
	NSDictionary *ruleStyle = [oneRun.attributes objectForKey:DTHorizontalRuleStyleAttribute];
	
	if (!ruleStyle)
	{
		return;
	}
	
	DTColor *color = [oneRun.attributes foregroundColor];
	CGContextSetStrokeColorWithColor(context, color.CGColor);
	
	CGRect nrect = self.frame;
	nrect.origin = line.frame.origin;
	nrect.size.height = oneRun.frame.size.height;
	nrect.origin.y = round(nrect.origin.y + oneRun.frame.size.height/2.0f)+0.5f;
	
	DTTextBlock *textBlock = [[oneRun.attributes objectForKey:DTTextBlocksAttribute] lastObject];
	
	if (textBlock)
	{
		// apply horizontal padding
		nrect.size.width = _frame.size.width - textBlock.padding.left - textBlock.padding.right;
	}
	
	CGContextMoveToPoint(context, nrect.origin.x, nrect.origin.y);
	CGContextAddLineToPoint(context, nrect.origin.x + nrect.size.width, nrect.origin.y);
	
	CGContextStrokePath(context);
}

- (void)drawInContext:(CGContextRef)context drawImages:(BOOL)drawImages drawLinks:(BOOL)drawLinks
{
	DTCoreTextLayoutFrameDrawingOptions options = DTCoreTextLayoutFrameDrawingDefault;
	
	if (!drawImages)
	{
		options |= DTCoreTextLayoutFrameDrawingOmitAttachments;
	}
	
	if (!drawLinks)
	{
		options |= DTCoreTextLayoutFrameDrawingOmitLinks;
	}
	
	[self drawInContext:context options:options];
}

// sets the text foreground color based on the glyph run and drawing options
- (void)_setForgroundColorInContext:(CGContextRef)context forGlyphRun:(DTCoreTextGlyphRun *)glyphRun options:(DTCoreTextLayoutFrameDrawingOptions)options
{
	DTColor *color = nil;
	
	BOOL needsToSetFillColor = [[glyphRun.attributes objectForKey:(id)kCTForegroundColorFromContextAttributeName] boolValue];
	
	if (glyphRun.isHyperlink)
	{
		if (options & DTCoreTextLayoutFrameDrawingDrawLinksHighlighted)
		{
			color = [glyphRun.attributes objectForKey:DTLinkHighlightColorAttribute];
		}
	}
	
	if (!color)
	{
		// get text color or use black
		color = [glyphRun.attributes foregroundColor];
	}
	
	// set fill for text that uses kCTForegroundColorFromContextAttributeName
	if (needsToSetFillColor)
	{
		CGContextSetFillColorWithColor(context, color.CGColor);
	}
	
	// set stroke for lines
	CGContextSetStrokeColorWithColor(context, color.CGColor);
}

- (void)drawInContext:(CGContextRef)context options:(DTCoreTextLayoutFrameDrawingOptions)options
{
	BOOL drawLinks = !(options & DTCoreTextLayoutFrameDrawingOmitLinks);
	BOOL drawImages = !(options & DTCoreTextLayoutFrameDrawingOmitAttachments);
	
	CGRect rect = CGContextGetClipBoundingBox(context);
	
	if (!context)
	{
		return;
	}
	
	if (_textFrame)
	{
		CFRetain(_textFrame);
	}
	
	
	if (_DTCoreTextLayoutFramesShouldDrawDebugFrames)
	{
		CGContextSaveGState(context);
		
		// stroke the frame because the layout frame might be open ended
		CGContextSaveGState(context);
		CGFloat dashes[] = {10.0, 2.0};
		CGContextSetLineDash(context, 0, dashes, 2);
		CGContextStrokeRect(context, self.frame);
		
		// draw center line
		CGContextMoveToPoint(context, CGRectGetMidX(self.frame), self.frame.origin.y);
		CGContextAddLineToPoint(context, CGRectGetMidX(self.frame), CGRectGetMaxY(self.frame));
		CGContextStrokePath(context);
		
		CGContextRestoreGState(context);
		
		CGContextSetRGBStrokeColor(context, 1, 0, 0, 0.5);
		CGContextStrokeRect(context, rect);
		
		CGContextRestoreGState(context);
	}
	
	NSArray *visibleLines = [self linesVisibleInRect:rect];
	
	if (![visibleLines count])
	{
		return;
	}
	
	CGContextSaveGState(context);
	
#if TARGET_OS_IPHONE
	// need to push the CG context so that the UI* based colors can be set
	UIGraphicsPushContext(context);
#endif
	
	// need to draw all text boxes because the the there might be the padding region of a box outside the clip rect visible
	[self _drawTextBlocksInContext:context inRange:NSMakeRange(0, [_attributedStringFragment length])];
	
	for (DTCoreTextLayoutLine *oneLine in visibleLines)
	{
		if ([oneLine isHorizontalRule])
		{
			[self _drawHorizontalRuleFromLine:oneLine inContext:context];
			continue;
		}
		
		if (_DTCoreTextLayoutFramesShouldDrawDebugFrames)
		{
			// draw line bounds
			CGContextSetRGBStrokeColor(context, 0, 0, 1.0f, 1.0f);
			CGContextStrokeRect(context, oneLine.frame);
			
			// draw baseline
			CGContextMoveToPoint(context, oneLine.baselineOrigin.x-5.0f, oneLine.baselineOrigin.y);
			CGContextAddLineToPoint(context, oneLine.baselineOrigin.x + oneLine.frame.size.width + 5.0f, oneLine.baselineOrigin.y);
			CGContextStrokePath(context);
		}
		
		NSInteger runIndex = 0;
		
		for (DTCoreTextGlyphRun *oneRun in oneLine.glyphRuns)
		{
			if (!CGRectIntersectsRect(rect, oneRun.frame))
			{
				continue;
			}
			
			if (_DTCoreTextLayoutFramesShouldDrawDebugFrames)
			{
				if (runIndex%2)
				{
					CGContextSetRGBFillColor(context, 1, 0, 0, 0.2f);
				}
				else
				{
					CGContextSetRGBFillColor(context, 0, 1, 0, 0.2f);
				}
				
				CGContextFillRect(context, oneRun.frame);
				runIndex ++;
			}
			
			DTTextAttachment *attachment = oneRun.attachment;
			
			if (drawImages && [attachment conformsToProtocol:@protocol(DTTextAttachmentDrawing)])
			{
				id<DTTextAttachmentDrawing> drawableAttachment = (id<DTTextAttachmentDrawing>)attachment;
				
				// frame might be different due to image vertical alignment
				CGFloat ascender = [attachment ascentForLayout];
				CGRect rect = CGRectMake(oneRun.frame.origin.x, oneLine.baselineOrigin.y - ascender, attachment.displaySize.width, attachment.displaySize.height);
				
				[drawableAttachment drawInRect:rect context:context];
			}
			
			if (!drawLinks && oneRun.isHyperlink)
			{
				continue;
			}
			
			// don't draw decorations on images
			if (attachment)
			{
				continue;
			}
			
			// don't draw background, strikeout or underline for trailing white space
			if ([oneRun isTrailingWhitespace])
			{
				continue;
			}
			
			[self _setForgroundColorInContext:context forGlyphRun:oneRun options:options];
			
			[oneRun drawDecorationInContext:context];
		}
	}
	
	// Flip the coordinate system
	CGContextSetTextMatrix(context, CGAffineTransformIdentity);
	CGContextScaleCTM(context, 1.0, -1.0);
	CGContextTranslateCTM(context, 0, -self.frame.size.height);
	
	// instead of using the convenience method to draw the entire frame, we draw individual glyph runs
	
	for (DTCoreTextLayoutLine *oneLine in visibleLines)
	{
		for (DTCoreTextGlyphRun *oneRun in oneLine.glyphRuns)
		{
			if (!CGRectIntersectsRect(rect, oneRun.frame))
			{
				continue;
			}
			
			if (!drawLinks && oneRun.isHyperlink)
			{
				continue;
			}
			
			CGPoint textPosition = CGPointMake(oneLine.frame.origin.x, self.frame.size.height - oneRun.frame.origin.y - oneRun.ascent);
			
			NSInteger superscriptStyle = [[oneRun.attributes objectForKey:(id)kCTSuperscriptAttributeName] integerValue];
			
			NSNumber *ascentMultiplier = [oneRun.attributes objectForKey:(id)DTAscentMultiplierAttribute];
			
			
			switch (superscriptStyle)
			{
				case 1:
				{
					textPosition.y += oneRun.ascent * (ascentMultiplier ? [ascentMultiplier floatValue] : 0.47f);
					break;
				}
				case -1:
				{
					textPosition.y -= oneRun.ascent * (ascentMultiplier ? [ascentMultiplier floatValue] : 0.25f);
					break;
				}
				default:
					break;
			}
			
			if (DTCoreTextModernAttributesPossible())
			{
				NSNumber *baselineOffset = oneRun.attributes[NSBaselineOffsetAttributeName];
				if (baselineOffset)
				{
					textPosition.y += [baselineOffset floatValue];
				}
			}
			
			CGContextSetTextPosition(context, textPosition.x, textPosition.y);
			
			if (!oneRun.attachment)
			{
				NSArray *shadows = [oneRun.attributes objectForKey:DTShadowsAttribute];
				
				if (shadows)
				{
					CGContextSaveGState(context);
					
					NSUInteger numShadows = [shadows count];
					
					if (numShadows == 1)
					{
						// single shadow, we only draw the glyph run with the shadow, no clipping magic
						NSDictionary *singleShadow = [shadows objectAtIndex:0];
						[self _setShadowInContext:context fromDictionary:singleShadow additionalOffset:CGSizeZero];
						
						[oneRun drawInContext:context];
					}
					else // multiple shadows, we shift the text away and then draw a single glyph run over it
					{
						// get the run bounds, Core Text has bottom left 0,0 so we flip it
						CGRect runBoundsFlipped = oneRun.frame;
						runBoundsFlipped.origin.y = self.frame.size.height - runBoundsFlipped.origin.y - runBoundsFlipped.size.height;
						
						// assume that shadows would never be more than 100 pixels away from glyph run frame or outside of frame
						CGRect clipRect = CGRectIntersection(CGRectInset(runBoundsFlipped, -100, -100), self.frame);
						
						// clip to the rect
						CGContextAddRect(context, clipRect);
						CGContextClipToRect(context, clipRect);
						
						// Move the text outside of the clip rect so that only the shadow is visible
						CGContextSetTextPosition(context, textPosition.x + clipRect.size.width, textPosition.y);
						
						// draw each shadow
						[shadows enumerateObjectsUsingBlock:^(NSDictionary *shadowDict, NSUInteger idx, BOOL *stop) {
							BOOL isLastShadow = (idx == (numShadows-1));
							
							if (isLastShadow)
							{
								// last shadow draws the original text
								[self _setShadowInContext:context fromDictionary:shadowDict additionalOffset:CGSizeZero];
								
								// ... so we put text position back
								CGContextSetTextPosition(context, textPosition.x, textPosition.y);
							}
							else
							{
								[self _setShadowInContext:context fromDictionary:shadowDict additionalOffset:CGSizeMake(-clipRect.size.width, 0)];
							}
							
							[oneRun drawInContext:context];
						}];
					}
					
					CGContextRestoreGState(context);
				}
				else // no shadows
				{
					[self _setForgroundColorInContext:context forGlyphRun:oneRun options:options];
					
					[oneRun drawInContext:context];
				}
			}
		}
	}
	
	if (_textFrame)
	{
		CFRelease(_textFrame);
	}
	
#if TARGET_OS_IPHONE
	UIGraphicsPopContext();
#endif
	
	CGContextRestoreGState(context);
}

#pragma mark - Text Attachments

- (NSArray *)textAttachments
{
	if (!_textAttachments)
	{
		NSMutableArray *tmpAttachments = [NSMutableArray array];
		
		for (DTCoreTextLayoutLine *oneLine in self.lines)
		{
			for (DTCoreTextGlyphRun *oneRun in oneLine.glyphRuns)
			{
				DTTextAttachment *attachment = [oneRun attachment];
				
				if (attachment)
				{
					[tmpAttachments addObject:attachment];
				}
			}
		}
		
		_textAttachments = [[NSArray alloc] initWithArray:tmpAttachments];
	}
	
	
	return _textAttachments;
}

- (NSArray *)textAttachmentsWithPredicate:(NSPredicate *)predicate
{
	return [[self textAttachments] filteredArrayUsingPredicate:predicate];
}

#pragma mark - Calculations

- (NSRange)visibleStringRange
{
	if (!_textFrame)
	{
		return NSMakeRange(0, 0);
	}
	
	if (!_lines)
	{
		// need to build lines to know range
		[self _buildLines];
	}
	
	return _stringRange;
}

- (NSArray *)stringIndices
{
	NSMutableArray *array = [NSMutableArray arrayWithCapacity:[self.lines count]];
	
	for (DTCoreTextLayoutLine *oneLine in self.lines)
	{
		[array addObjectsFromArray:[oneLine stringIndices]];
	}
	
	return array;
}

- (NSInteger)lineIndexForGlyphIndex:(NSInteger)index
{
	NSInteger retIndex = 0;
	for (DTCoreTextLayoutLine *oneLine in self.lines)
	{
		NSInteger count = [oneLine numberOfGlyphs];
		if (index >= count)
		{
			index -= count;
		}
		else
		{
			return retIndex;
		}
		
		retIndex++;
	}
	
	return retIndex;
}

- (CGRect)frameOfGlyphAtIndex:(NSInteger)index
{
	for (DTCoreTextLayoutLine *oneLine in self.lines)
	{
		NSInteger count = [oneLine numberOfGlyphs];
		if (index >= count)
		{
			index -= count;
		}
		else
		{
			return [oneLine frameOfGlyphAtIndex:index];
		}
	}
	
	return CGRectNull;
}

- (CGRect)frame
{
	if (!_lines)
	{
		[self _buildLines];
	}
	
	if (![self.lines count])
	{
		return CGRectZero;
	}
	
	if (_frame.size.height == CGFLOAT_HEIGHT_UNKNOWN)
	{
		// actual frame is spanned between first and last lines
		DTCoreTextLayoutLine *lastLine = [_lines lastObject];
		
		_frame.size.height = ceil((CGRectGetMaxY(lastLine.frame) - _frame.origin.y + 1.5f + _additionalPaddingAtBottom));
	}
	
	if (_frame.size.width == CGFLOAT_WIDTH_UNKNOWN)
	{
		// actual frame width is maximum value of lines
		CGFloat maxWidth = 0;
		
		for (DTCoreTextLayoutLine *oneLine in _lines)
		{
			CGFloat lineWidthFromFrameOrigin = CGRectGetMaxX(oneLine.frame) - _frame.origin.x;
			maxWidth = MAX(maxWidth, lineWidthFromFrameOrigin);
		}
		
		_frame.size.width = ceil(maxWidth);
	}
	
	return _frame;
}

- (CGRect)intrinsicContentFrame
{
	if (!_lines)
	{
		[self _buildLines];
	}
	
	if (![self.lines count])
	{
		return CGRectZero;
	}
	
	DTCoreTextLayoutLine *firstLine = [_lines objectAtIndex:0];
	
	CGRect outerFrame = self.frame;
	
	CGRect frameOverAllLines = firstLine.frame;
	
	// move up to frame origin because first line usually does not go all the ways up
	frameOverAllLines.origin.y = outerFrame.origin.y;
	
	for (DTCoreTextLayoutLine *oneLine in _lines)
	{
		// need to limit frame to outer frame, otherwise HR causes too long lines
		CGRect frame = CGRectIntersection(oneLine.frame, outerFrame);
		
		frameOverAllLines = CGRectUnion(frame, frameOverAllLines);
	}
	
	// extend height same method as frame
	frameOverAllLines.size.height = ceil(frameOverAllLines.size.height + 1.5f + _additionalPaddingAtBottom);
	
	return CGRectIntegral(frameOverAllLines);
}

- (DTCoreTextLayoutLine *)lineContainingIndex:(NSUInteger)index
{
	for (DTCoreTextLayoutLine *oneLine in self.lines)
	{
		if (NSLocationInRange(index, [oneLine stringRange]))
		{
			return oneLine;
		}
	}
	
	return nil;
}

- (NSArray *)linesInParagraphAtIndex:(NSUInteger)index
{
	NSArray *paragraphRanges = self.paragraphRanges;
	
	NSAssert(index < [paragraphRanges count], @"index parameter out of range");
	
	NSRange range = [[paragraphRanges objectAtIndex:index] rangeValue];
	
	NSMutableArray *tmpArray = [NSMutableArray array];
	
	// find lines that are in this range
	
	BOOL insideParagraph = NO;
	
	for (DTCoreTextLayoutLine *oneLine in self.lines)
	{
		if (NSLocationInRange([oneLine stringRange].location, range))
		{
			insideParagraph = YES;
			[tmpArray addObject:oneLine];
		}
		else
		{
			if (insideParagraph)
			{
				// that means we left the range
				
				break;
			}
		}
	}
	
	// return array only if there is something in it
	if ([tmpArray count])
	{
		return tmpArray;
	}
	else
	{
		return nil;
	}
}

// returns YES if the given line is the first in a paragraph
- (BOOL)isLineFirstInParagraph:(DTCoreTextLayoutLine *)line
{
	NSRange lineRange = line.stringRange;
	
	if (lineRange.location == 0)
	{
		return YES;
	}
	
	NSInteger prevLineLastUnicharIndex =lineRange.location - 1;
	unichar prevLineLastUnichar = [[_attributedStringFragment string] characterAtIndex:prevLineLastUnicharIndex];
	
	return [[NSCharacterSet newlineCharacterSet] characterIsMember:prevLineLastUnichar];
}

// returns YES if the given line is the last in a paragraph
- (BOOL)isLineLastInParagraph:(DTCoreTextLayoutLine *)line
{
	NSString *lineString = [[_attributedStringFragment string] substringWithRange:line.stringRange];
	
	if ([lineString hasSuffix:@"\n"])
	{
		return YES;
	}
	
	return NO;
}

#pragma mark - Paragraphs
- (NSUInteger)paragraphIndexContainingStringIndex:(NSUInteger)stringIndex
{
	for (NSValue *oneValue in self.paragraphRanges)
	{
		NSRange range = [oneValue rangeValue];
		
		if (NSLocationInRange(stringIndex, range))
		{
			return [self.paragraphRanges indexOfObject:oneValue];
		}
	}
	
	return NSNotFound;
}

- (NSRange)paragraphRangeContainingStringRange:(NSRange)stringRange
{
	NSUInteger firstParagraphIndex = [self paragraphIndexContainingStringIndex:stringRange.location];
	NSUInteger lastParagraphIndex;
	
	if (stringRange.length)
	{
		lastParagraphIndex = [self paragraphIndexContainingStringIndex:NSMaxRange(stringRange)-1];
	}
	else
	{
		// range is in a single position, i.e. last paragraph has to be same as first
		lastParagraphIndex = firstParagraphIndex;
	}
	
	return NSMakeRange(firstParagraphIndex, lastParagraphIndex - firstParagraphIndex + 1);
}

#pragma mark - Debugging
+ (void)setShouldDrawDebugFrames:(BOOL)debugFrames
{
	_DTCoreTextLayoutFramesShouldDrawDebugFrames = debugFrames;
}

+ (BOOL)shouldDrawDebugFrames
{
	return _DTCoreTextLayoutFramesShouldDrawDebugFrames;
}

#pragma mark - Properties
- (NSAttributedString *)attributedStringFragment
{
	return _attributedStringFragment;
}

// builds an array
- (NSArray *)paragraphRanges
{
	if (!_paragraphRanges)
	{
		NSString *plainString = [[self attributedStringFragment] string];
		NSUInteger length = [plainString length];
		
		NSRange paragraphRange = [plainString rangeOfParagraphsContainingRange:NSMakeRange(0, 0) parBegIndex:NULL parEndIndex:NULL];
		
		NSMutableArray *tmpArray = [NSMutableArray array];
		
		while (paragraphRange.length)
		{
			NSValue *value = [NSValue valueWithRange:paragraphRange];
			[tmpArray addObject:value];
			
			NSUInteger nextParagraphBegin = NSMaxRange(paragraphRange);
			
			if (nextParagraphBegin>=length)
			{
				break;
			}
			
			// next paragraph
			paragraphRange = [plainString rangeOfParagraphsContainingRange:NSMakeRange(nextParagraphBegin, 0) parBegIndex:NULL parEndIndex:NULL];
		}
		
		_paragraphRanges = tmpArray; // no copy for performance
	}
	
	return _paragraphRanges;
}

- (void)setNumberOfLines:(NSInteger)numberOfLines
{
    if( _numberOfLines != numberOfLines )
	{
		_numberOfLines = numberOfLines;
        // clear lines cache
        _lines = nil;
    }
}

- (void)setLineBreakMode:(NSLineBreakMode)lineBreakMode
{
    if( _lineBreakMode != lineBreakMode )
	{
        _lineBreakMode = lineBreakMode;
        // clear lines cache
        _lines = nil;
    }
}

- (void)setTruncationString:(NSAttributedString *)truncationString
{
    if( ![_truncationString isEqualToAttributedString:truncationString] )
	{
        _truncationString = truncationString;
		
        if( self.numberOfLines > 0 )
		{
            // clear lines cache
            _lines = nil;
        }
    }
}

- (void)setJustifyRatio:(CGFloat)justifyRatio
{
	if (_justifyRatio != justifyRatio)
	{
		_justifyRatio = justifyRatio;
		
        // clear lines cache
        _lines = nil;
    }
}

@synthesize numberOfLines = _numberOfLines;
@synthesize lineBreakMode = _lineBreakMode;
@synthesize truncationString = _truncationString;
@synthesize frame = _frame;
@synthesize lines = _lines;
@synthesize paragraphRanges = _paragraphRanges;
@synthesize textBlockHandler = _textBlockHandler;
@synthesize justifyRatio = _justifyRatio;

@end
