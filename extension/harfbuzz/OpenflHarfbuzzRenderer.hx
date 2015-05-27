package extension.harfbuzz;

import openfl.display.BitmapData;
import openfl.display.Sprite;
import openfl.geom.Point;
import openfl.geom.Rectangle;
import extension.harfbuzz.OpenflHarbuzzCFFI;
import extension.harfbuzz.TextScript;
import openfl.Lib;

class OpenflHarfbuzzRenderer {

	static var harfbuzzIsInited = false;

	var direction : TextDirection;
	var script : TextScript;
	var language : String;
	var lineHeight : Float;

	var face : FTFace;
	var renderer : TilesRenderer;
	var glyphs : Map<Int, GlyphRect>;

	public function new(
			ttfPath : String,
			textSize : Int,
			text : String,
			language : String = "",
			script : TextScript = null,
			direction : TextDirection = null) {

		if (script==null) {
			script = ScriptIdentificator.identify(text);
		}
		this.script = script;

		if (direction==null) {
			direction = TextScriptTools.isRightToLeft(script) ? RightToLeft : LeftToRight;
		}
		this.direction = direction;

		this.language = language;
		this.lineHeight = textSize;

		if (!harfbuzzIsInited) {
			OpenflHarbuzzCFFI.init();
		}

		face = OpenflHarbuzzCFFI.loadFontFaceFromMemory(openfl.Assets.getBytes(ttfPath).getData());

		OpenflHarbuzzCFFI.setFontSize(face, textSize);

		//var time = Lib.getTimer();
		//trace("1 start");
		
		var glyphAtlasResult = OpenflHarbuzzCFFI.createGlyphAtlas(face, createBuffer(text));
		var glyphsBmp = new BitmapData(glyphAtlasResult.width, glyphAtlasResult.height);
		
		//trace("2 : " + (Lib.getTimer() - time));
		//time = Lib.getTimer();

		var rect = new Rectangle(0, 0, glyphsBmp.width, glyphsBmp.height);
		var ct = new openfl.geom.ColorTransform(1,1,1,1,255,255,255,0);
		glyphsBmp.setVector(rect, glyphAtlasResult.bmpData);
		glyphsBmp.colorTransform(rect, ct);

		//trace("3 : " + (Lib.getTimer() - time));
		//time = Lib.getTimer();

		glyphs = new Map();
		var glyphsRects = new Array<{ codepoint : Int, rect : Rectangle }>();
		for (rect in glyphAtlasResult.glyphRects) {
			glyphs[rect.codepoint] = rect;
			glyphsRects.push({ codepoint : rect.codepoint, rect : new Rectangle(rect.x, rect.y, rect.width, rect.height) });
		}

		renderer = new TilesRenderer(glyphsBmp, glyphsRects);

	}

	function createBuffer(text : String) : HBBuffer {
		return OpenflHarbuzzCFFI.createBuffer(direction, script, language, text);
	}

	// Splits text into words containging the trailing spaces ("a b c"=["a ", "b ", "c "])
	function split(text : String) : Array<String> {
		var ret = [];
		var currentWord = "";
		for (i in 0...text.length) {
			if (StringTools.isSpace(text, i)) {
				if(currentWord.length>0) ret.push(currentWord);
				if(text.charAt(i)!="\r") ret.push(text.charAt(i));
				currentWord = "";
			} else {
				currentWord+=text.charAt(i);				
			}
		}
		if (currentWord.length>0) {
			ret.push(currentWord);
		}
		return ret;
	}

	function layouWidth(layout : Array<PosInfo>) : Float {
		var xPos = 0.0;
		for (posInfo in layout) {
			xPos += posInfo.advance.x / (100/64);	// 100/64 = 1.5625 = Magic!
		}
		return xPos;
	}

	function isEndOfLine(xPos : Float, wordWidth : Float, lineWidth : Float) {
		if (direction == LeftToRight) {
			return (xPos>0.0 && xPos+wordWidth>lineWidth);
		} else {	// RightToLeft
			return (xPos<lineWidth&& xPos-wordWidth<0.0);
		}
	}

	// if "text" is in RtoL script, invert non-RtoL substrings
	function preProcessText(text : String) {

		var generalTextIsRtoL = TextScriptTools.isRightToLeft(script);
		var words = split(text);
		var arr : Array<{text : String, invert : Bool}> = [{ text : "", invert : false }];
		for (word in words) {
			var shouldInvertCurrentWord = TextScriptTools.isRightToLeft(ScriptIdentificator.identify(word))!=generalTextIsRtoL;
			var currentPhrase = arr[arr.length-1];
			if (currentPhrase.invert==shouldInvertCurrentWord) {
				currentPhrase.text += word;
			} else {
				arr.push({ text : word, invert : shouldInvertCurrentWord });
			}
		}

		var ret = "";
		for (a in arr) {
			var phrase = a.text;
			if (a.invert) {
		    	var inverted = "";
		    	var i = phrase.length;
		    	while (i>0) {
		    		i--;
		    		inverted += phrase.charAt(i);
		    	}
		    	phrase = inverted;
			}
			ret += phrase;
		}

		return ret;

	}

	public function renderText(text : String, lineWidth : Float, color : Int) : HarfbuzzSprite {

		text = preProcessText(text);

		var renderList = new Array<{ codepoint : Int, x : Float, y : Float }>();
		var words = split(text);

		var lineNumber : Int = 1;
		var maxLineWidth = 400;

		var lineXStart = direction==LeftToRight ? 0.0 : lineWidth;
		var xPosBase : Float = lineXStart;
		var yPosBase : Float = lineNumber*lineHeight;

		for (word in words) {
			var renderedWord = OpenflHarbuzzCFFI.layoutText(face, createBuffer(word));
			var wordWidth = layouWidth(renderedWord);

			if (word == "\n" || isEndOfLine(xPosBase, wordWidth, lineWidth)) {
				// Newline
				lineNumber++;
				xPosBase = lineXStart;
				yPosBase = lineNumber*lineHeight;
				if(StringTools.isSpace(word,0)) continue;
			}

			var xPos = xPosBase;
			if (direction==RightToLeft)	xPos-=wordWidth;
			var yPos = yPosBase;

			for (posInfo in renderedWord) {

				var g = glyphs[posInfo.codepoint];
				if(g==null) {
					trace("WOW! I'm missing a glyph for the following word: "+word);
					trace("This should not be happening! Your text will be renderer badly :(");
					trace("CODEPINT "+posInfo.codepoint);
					trace(posInfo);
					continue;
				}
				var dstX = Std.int(xPos + posInfo.offset.x + g.bitmapLeft);
				var dstY = Std.int(yPos + posInfo.offset.y - g.bitmapTop);
				var avanceX = posInfo.advance.x / (100/64); // 100/64 = 1.5625 = Magic!
				var avanceY = posInfo.advance.y / (100/64);

				if (xPos+avanceX>=lineWidth && direction==LeftToRight) {
					// Newline
					lineNumber++;
					xPos = 0;
					yPos = lineNumber*lineHeight;
					dstX = Std.int(xPos + posInfo.offset.x + g.bitmapLeft);
					dstY = Std.int(yPos + posInfo.offset.y - g.bitmapTop);
				}

				renderList.push({ codepoint : g.codepoint, x : dstX, y : dstY });

				xPos += avanceX;
				yPos += avanceY;
			}

			if (direction==LeftToRight) {
				xPosBase += wordWidth;
			} else {
				xPosBase -= wordWidth;
			}

		}

		return renderer.render(lineWidth, (lineNumber)*lineHeight, renderList, ((color>>16)&0xff)/255.0, ((color>>8)&0xff)/255.0, (color&0xff)/255.0);

	}

}
