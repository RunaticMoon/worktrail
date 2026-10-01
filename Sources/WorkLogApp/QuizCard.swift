#if os(macOS)
import SwiftUI
import WorkLogCore

struct QuizCard: View {
    @Bindable var model: QuizModel
    let reportDate: WorkDate
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("성과 보충 질문").font(.headline)
            Text("답변은 성과 기록용이며 제출용 본문에 자동으로 들어가지 않습니다. 건너뛰어도 보고를 확정·복사할 수 있습니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.isAvailable {
                Button("질문 생성") { Task { await model.generate(reportDate: reportDate) } }.disabled(!model.canGenerate)
            } else { Text("AI 연결을 사용할 수 없어 보충 질문 생성이 비활성화되어 있습니다.").foregroundStyle(.secondary) }
            if model.isGenerating { ProgressView("보충 질문 생성 중…") }
            if let message = model.message { InlineNotice(message: message) }
            ForEach(model.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.question).font(.body.weight(.medium))
                    if let context = question.context { Text(context).font(.callout).foregroundStyle(.secondary) }
                    ReportRangeLabel(title: "설명 대상 기간", range: question.applies)
                    if let outcome = model.recorded[question.id] {
                        Label(outcomeTitle(outcome), systemImage: "checkmark.circle")
                    } else {
                        TextField("답변", text: Binding(get: { model.answers[question.id] ?? "" }, set: { model.answers[question.id] = $0 }), axis: .vertical)
                            .lineLimit(2...6).textFieldStyle(.roundedBorder).accessibilityLabel("\(question.question) 답변")
                        ViewThatFits(in: .horizontal) {
                            HStack { actions(question) }
                            VStack(alignment: .leading) { actions(question) }
                        }
                    }
                    Divider()
                }.padding(.vertical, 4)
            }
        }.onChange(of: reportDate) { _, _ in model.reset() }
    }
    @ViewBuilder private func actions(_ question: QuizQuestion) -> some View {
        Button("답변 저장") { model.record(question.id, outcome: .answered) }
            .disabled((model.answers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("확인한 결과 없음") { model.record(question.id, outcome: .noResult) }
        Button("나중에") { model.record(question.id, outcome: .later) }
        Button("이 질문 제외") { model.record(question.id, outcome: .excluded) }
    }
    private func outcomeTitle(_ outcome: SupplementOutcome) -> String {
        switch outcome {
        case .answered: return "답변 저장됨"
        case .noResult: return "확인한 결과 없음으로 기록됨"
        case .later: return "나중에 답변하기로 기록됨"
        case .excluded: return "질문 제외됨"
        }
    }
}
#endif
