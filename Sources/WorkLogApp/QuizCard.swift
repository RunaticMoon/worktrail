#if os(macOS)
import SwiftUI
import WorkLogCore

@MainActor
struct QuizCard: View {
    @Bindable var model: QuizModel
    let reportDate: WorkDate
    @State private var retryAction: RetryAction = .generate
    private enum RetryAction { case generate, record(String, SupplementOutcome) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("성과 보충 질문").font(.headline).accessibilityAddTraits(.isHeader)
            Text("질문은 선택 사항입니다. 모두 건너뛰어도 보고서를 복사·확정할 수 있습니다.")
                .font(.callout).foregroundStyle(WorkLogTheme.muted).fixedSize(horizontal: false, vertical: true)
            Text("답변은 성과 근거로 기록되며, 팀 제출용 본문에 자동으로 들어가지 않습니다.")
                .font(.caption).foregroundStyle(WorkLogTheme.muted).fixedSize(horizontal: false, vertical: true)
            Button("질문 생성") { generate() }
                .disabled(!model.canGenerate || model.remainingCount > 0)
                .worklogHelp("기록에서 보충할 성과 질문 생성 · 남은 질문 처리 후 다시 생성 가능")
            if !model.isAvailable {
                StateView(kind: .aiUnavailable, title: "AI 연결 없음", detail: "질문 생성은 나중에 사용할 수 있습니다. 보고서는 계속 편집·복사·확정할 수 있습니다.")
            }
            if model.isGenerating {
                StateView(kind: .loading, title: "보충 질문 생성 중…", detail: "보고서 복사와 계획 검토는 계속할 수 있습니다.")
            }
            if let message = model.message {
                if isFailure(message) {
                    RecoveryNotice(failed: message, preserved: "입력한 답변과 보고서 본문은 그대로 보존됩니다.",
                                   retryTitle: "다시 시도", retry: { retry() })
                        .disabled(model.isGenerating || cannotRetryGeneration)
                } else {
                    InlineNotice(message: message).accessibilityLabel("성과 질문 안내: \(message)")
                }
            }
            if let question = model.currentQuestion {
                Text("\(model.remainingCount)개 남음").font(.callout).accessibilityLabel("성과 질문 \(model.remainingCount)개 남음")
                questionCard(question)
                HStack(spacing: 8) {
                    Button("이전 질문") { model.showPrevious() }.disabled(!hasPrevious(question))
                        .worklogHelp("기록하지 않은 이전 질문 보기 · 답변 입력 유지")
                    Button("다음 질문") { model.showNext() }.disabled(!hasNext(question))
                        .worklogHelp("기록하지 않은 다음 질문 보기 · 답변 입력 유지")
                }
            } else if !model.questions.isEmpty {
                StatusBadge(label: "남은 질문 없음", systemImage: "checkmark.circle", tone: .success)
                DisclosureGroup("질문 기록 \(model.recorded.count)개") {
                    ForEach(model.questions) { question in
                        if let outcome = model.recorded[question.id] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(question.question)
                                Label(outcomeTitle(outcome), systemImage: "checkmark.circle").font(.callout)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            } else if model.isAvailable && !model.isGenerating && model.message == nil {
                Text("필요할 때 질문을 생성해 지난주 성과 근거를 보충하세요.").font(.callout).foregroundStyle(WorkLogTheme.muted)
            }
        }.onChange(of: reportDate) { _, _ in model.reset(); retryAction = .generate }
    }
    private func questionCard(_ question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            if let context = question.context { Text(context).font(.callout).foregroundStyle(WorkLogTheme.muted) }
            ReportRangeLabel(title: "설명 대상 기간", range: question.applies)
            TextField("답변", text: Binding(get: { model.answers[question.id] ?? "" }, set: { model.answers[question.id] = $0 }), axis: .vertical)
                .lineLimit(2...6).textFieldStyle(.roundedBorder).accessibilityLabel("\(question.question) 답변")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions(question) }
                VStack(alignment: .leading, spacing: 8) { actions(question) }
            }
        }.worklogCard()
    }
    @ViewBuilder private func actions(_ question: QuizQuestion) -> some View {
        Button("답변 기록") { record(question.id, outcome: .answered) }
            .disabled((model.answers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .worklogHelp("답변을 성과 보충 근거로 기록")
        Button("결과 없음") { record(question.id, outcome: .noResult) }.worklogHelp("확인한 결과 없음으로 기록")
        Button("나중에") { record(question.id, outcome: .later) }.worklogHelp("나중에 답변하기로 기록")
        Button("제외") { record(question.id, outcome: .excluded) }.worklogHelp("이 질문 제외로 기록")
    }
    private func generate() {
        retryAction = .generate
        Task { await model.generate(reportDate: reportDate) }
    }
    private func record(_ id: String, outcome: SupplementOutcome) {
        retryAction = .record(id, outcome)
        model.record(id, outcome: outcome)
    }
    private func isFailure(_ message: String) -> Bool {
        // Match only the model's explicit failure messages; keep validation warnings as notices.
        message.hasPrefix("질문을 생성하지 못했습니다.")
            || message.hasPrefix("질문 생성 상태:")
            || message.hasPrefix("답변을 저장하지 못했습니다.")
    }
    private var cannotRetryGeneration: Bool {
        if case .generate = retryAction { return !model.canGenerate || model.remainingCount > 0 }
        return false
    }
    private func retry() {
        switch retryAction {
        case .generate: if !cannotRetryGeneration { generate() }
        case .record(let id, let outcome): record(id, outcome: outcome)
        }
    }
    private func hasPrevious(_ question: QuizQuestion) -> Bool {
        guard let index = model.questions.firstIndex(where: { $0.id == question.id }) else { return false }
        return model.questions.prefix(index).contains { model.recorded[$0.id] == nil }
    }
    private func hasNext(_ question: QuizQuestion) -> Bool {
        guard let index = model.questions.firstIndex(where: { $0.id == question.id }) else { return false }
        return model.questions.dropFirst(index + 1).contains { model.recorded[$0.id] == nil }
    }
    private func outcomeTitle(_ outcome: SupplementOutcome) -> String {
        switch outcome {
        case .answered: return "답변 기록됨"
        case .noResult: return "확인한 결과 없음으로 기록됨"
        case .later: return "나중에 답변하기로 기록됨"
        case .excluded: return "질문 제외됨"
        }
    }
}
#endif
