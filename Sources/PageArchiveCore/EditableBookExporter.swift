import Foundation

public enum EditableBookExporter {
    public static func paragraphBoundary(from left:Page,to right:Page)->(tail:Block,head:Block)? {
        guard let tail=left.orderedBodyBlocks.last,let head=right.orderedBodyBlocks.first,
              tail.kind == .paragraph,head.kind == .paragraph,!tail.text.isEmpty,!head.text.isEmpty else{return nil}
        return (tail,head)
    }

    public static func exportMarkdown(document:BookDocument,pages:[Int],to url:URL,
                                      cancelled:()->Bool = {false},progress:(Int,Int)->Void = {_,_ in}) throws {
        guard pages.allSatisfy({document.pages.indices.contains($0)}) else {throw ArchiveError.message("导出页范围超出项目页数。")}
        var body:[String]=[],notes:[String]=[]
        var previousIndex:Int?
        progress(0,pages.count)
        for (offset,index) in pages.enumerated() {
            if cancelled(){throw CancellationError()}
            let page=document.pages[index]
            let blocks=page.orderedBodyBlocks
            var skipHead=false
            if let previousIndex=previousIndex,previousIndex+1==index,
               let join=document.pages[previousIndex].textContinuation,join.nextPageID==page.id,
               let boundary=paragraphBoundary(from:document.pages[previousIndex],to:page),
               join.tailBlockID==boundary.tail.id,join.headBlockID==boundary.head.id,!body.isEmpty {
                body[body.count-1]=trailingTrim(body[body.count-1])+join.separator.text+leadingTrim(render(boundary.head))
                skipHead=true
            }
            body.append(contentsOf:blocks.dropFirst(skipHead ? 1 : 0).map(render))
            if page.blocks.isEmpty,page.status != .blank {body.append("〔第 \(index+1) 页待识别〕")}
            let footnotes=page.orderedBlocks.filter{$0.kind == .footnote}
            if !footnotes.isEmpty {
                notes.append("## 脚注（第 \(escape(page.printedLabel ?? String(index+1))) 页）")
                notes.append(contentsOf:footnotes.map(render))
            }
            previousIndex=index
            progress(offset+1,pages.count)
        }
        if cancelled(){throw CancellationError()}
        let content=(body+notes).filter{!$0.isEmpty}.joined(separator:"\n\n")+"\n"
        try content.write(to:url,atomically:true,encoding:.utf8)
    }

    private static func leadingTrim(_ text:String)->String {String(text.drop(while:\.isWhitespace))}
    private static func trailingTrim(_ text:String)->String {String(text.reversed().drop(while:\.isWhitespace).reversed())}
    private static func escapeHTML(_ text:String)->String {
        text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;")
            .replacingOccurrences(of:">",with:"&gt;")
    }
    private static func escape(_ text:String)->String {
        let punctuation:Set<Character>=Set("\\[]\u{60}*_{}#!+|~.-")
        return escapeHTML(text).reduce(into:"") { result,character in
            if punctuation.contains(character){result.append("\\")}
            result.append(character)
        }
    }
    private static func render(_ block:Block)->String {
        if block.kind == .heading {return "## "+escape(block.text.replacingOccurrences(of:"\n",with:" "))}
        if block.kind == .figure || block.retainImage {
            return block.text.isEmpty ? "〔\(block.kind.label)参见原页〕" : escape(block.text)
        }
        if block.kind != .table {return escape(block.text)}
        let cells=block.cells.sorted{($0.row,$0.column)<($1.row,$1.column)}
        if cells.isEmpty {return block.text.isEmpty ? "〔表格待核对〕" : escape(block.text)}
        var occupied=Set<Int>()
        var rowEnd=0,columnEnd=0
        func fallback()->String {
            cells.map{"- 行 \($0.row)，列 \($0.column) · "+escape($0.text)}.joined(separator:"\n")
        }
        for cell in cells {
            guard (0..<500).contains(cell.row),(0..<100).contains(cell.column),
                  (1...100).contains(cell.rowSpan),(1...100).contains(cell.columnSpan),
                  cell.row+cell.rowSpan<=500,cell.column+cell.columnSpan<=100 else{return fallback()}
            rowEnd=max(rowEnd,cell.row+cell.rowSpan);columnEnd=max(columnEnd,cell.column+cell.columnSpan)
            for row in cell.row..<cell.row+cell.rowSpan {
                for column in cell.column..<cell.column+cell.columnSpan {
                    if !occupied.insert(row*100+column).inserted{return fallback()}
                }
            }
        }
        guard occupied.count==rowEnd*columnEnd else{return fallback()}
        let rows=Dictionary(grouping:cells,by:\.row)
        let lines=(0..<rowEnd).map { row -> String in
            let columns=(rows[row] ?? []).map { cell in
                let value=escapeHTML(cell.text).replacingOccurrences(of:"\n",with:"<br>")
                return "<td rowspan=\"\(cell.rowSpan)\" colspan=\"\(cell.columnSpan)\">\(value)</td>"
            }
            return "<tr>"+columns.joined()+"</tr>"
        }
        return (["<table>"]+lines+["</table>"]).joined(separator:"\n")
    }
}
