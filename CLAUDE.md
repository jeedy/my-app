# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

Vite + React 19 + TypeScript 스타터입니다. 소스는 `.tsx`, Node 측 설정 파일(`vite.config.ts`, `eslint.config.ts`)도 모두 TypeScript로 작성되어 있습니다. 테스트 프레임워크는 설정되어 있지 않습니다.

## 주요 명령어

- `npm run dev` — Vite 개발 서버 실행 (HMR 활성화)
- `npm run build` — `tsc -b` 타입 체크 + Vite 프로덕션 빌드. 타입 오류가 있으면 빌드 실패
- `npm run preview` — 빌드 결과물 로컬 미리보기
- `npm run lint` — ESLint 검사 (`.ts/.tsx` 대상)
- 특정 파일만 린트: `npx eslint <파일경로>`
- 타입만 단독 확인: `npx tsc -b --noEmit`

## 아키텍처 메모

- 진입점은 `src/main.tsx` → `src/App.tsx`이며, `StrictMode`로 래핑되어 있습니다. `index.html`이 Vite의 HTML 진입점입니다.
- `public/` 디렉터리의 파일은 절대 경로(`/icons.svg` 등)로 직접 참조됩니다. `src/assets/`의 이미지는 `import`로 가져옵니다 — 두 방식을 혼동하지 마세요. 정적 자산 타입은 `src/vite-env.d.ts`의 `vite/client` 참조로 제공됩니다.
- TypeScript는 프로젝트 레퍼런스로 3-파일 구조입니다: 루트 `tsconfig.json`(레퍼런스만 보유), `tsconfig.app.json`(`src/` 앱 코드), `tsconfig.node.json`(`vite.config.ts`, `eslint.config.ts` 등 Node 측). 새 Node용 설정 파일을 추가하면 `tsconfig.node.json`의 `include`에 등록하세요.
- ESLint는 flat config(`eslint.config.ts`)이며, `eslint.config.ts`를 읽기 위해 `jiti`가 devDependency로 필요합니다. `typescript-eslint`의 비-타입 인식 권장 룰셋과 `react-hooks`, `react-refresh/vite`가 활성화되어 있습니다. typed-linting(타입 인식 룰)은 일부러 비활성화 — 활성화하려면 `parserOptions.project`를 지정하고 `recommendedTypeChecked`로 바꾸어야 합니다.
- React Compiler는 의도적으로 비활성화되어 있습니다 (README 참조). 활성화 시 dev/build 성능에 영향이 있으므로 임의로 켜지 마세요.
