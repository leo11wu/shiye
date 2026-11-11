import Foundation

public enum Fixtures {
    public static func document() -> BookDocument {
        var d=BookDocument(title:"拾页 · 原生排版技术样张（已知文本，非 OCR 结果）")
        var p=Page(id:"fixture-1",sourcePage:1,width:595.28,height:841.89)
        var heading=Block(id:"title",kind:.heading,order:1,box:Box(0.09,0.07,0.82,0.08),text:"拾页 · 原文重建",fontSize:23)
        heading.runs=[TextRun(heading.rawText,style:TextStyle(bold:true))]
        let sub=Block(id:"sub",order:2,box:Box(0.09,0.155,0.82,0.05),text:"技术样张 / 已知文字排版 / 本页不代表古书 OCR 准确率",fontSize:10)
        let english=Block(id:"english",order:3,box:Box(0.09,0.245,0.82,0.14),text:"Historical documents deserve faithful transcription.\nPreserve paragraph structure, original spelling, footnotes,\nand phonetic distinctions. Clear type supports continuous\nreading while every region remains traceable to its source.",fontSize:13)
        let chinese=Block(id:"chinese",order:4,box:Box(0.09,0.41,0.82,0.08),text:"繁體原文：語音、聲調、異體字與歷史拼寫均應保留。\n简体说明：更换字体与排版不会重新调用识别接口。",fontSize:12)
        let ipa=Block(id:"ipa",order:5,box:Box(0.09,0.525,0.82,0.075),text:"Phonetics: ɑ̃  n̩  d̥  ɕ  ʑ  ɣ  tʰ  aː  ŋ  t͡s",fontSize:16)
        var scripts=Block(id:"scripts",order:6,box:Box(0.09,0.615,0.82,0.05),text:"Styles: italic; H2O; x2.",fontSize:14)
        scripts.runs=[TextRun("Styles: "),TextRun("italic",style:TextStyle(italic:true)),TextRun("; H"),TextRun("2",style:TextStyle(script:-1)),TextRun("O; x"),TextRun("2",style:TextStyle(script:1)),TextRun(".")]
        var table=Block(id:"table",kind:.table,order:7,box:Box(0.09,0.70,0.82,0.13),fontSize:11)
        table.drawGrid=true
        for (r,row) in [["原文","拟音","说明"],["聲","ɕiəŋ","保留附标"],["語","ŋɨəʔ","保持列关系"]].enumerated() {
            for (c,text) in row.enumerated() { table.cells.append(TableCell(id:"cell-\(r)-\(c)",row:r,column:c,text:text)) }
        }
        let note=Block(id:"note",kind:.footnote,order:8,box:Box(0.09,0.875,0.82,0.055),text:"1. 本页文字由程序预先提供，用来检查字体、布局和 PDF 复制。\n实际扫描文献需要配置视觉 API 后另行识别与人工核对。",fontSize:9)
        for b in [heading,sub,english,chinese,ipa,scripts,table,note] { var b=b;b.reviewed=true;p.blocks.append(b) }
        p.status = .reviewed;d.pages=[p];return d
    }
}
