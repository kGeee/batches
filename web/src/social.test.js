import { describe, expect, it } from 'vitest'
import { parseRoute, splitMentions } from './ui.jsx'

describe('routes, mentions and notification links', () => {
  it('parses /app/notifications route', () => {
    expect(parseRoute('/app/notifications', '')).toEqual({ page: 'notifications' })
  })

  it('parses batch and photo deep links from notifications', () => {
    expect(parseRoute('/b/11000000-0000-0000-0000-000000000001', '?photo=22000000-0000-0000-0000-000000000002')).toEqual({
      page: 'batch',
      id: '11000000-0000-0000-0000-000000000001',
      photo: '22000000-0000-0000-0000-000000000002',
    })
  })

  it('parses profile routes for @handle mention links', () => {
    expect(parseRoute('/app/u/maya.r', '')).toEqual({ page: 'profile', handle: 'maya.r' })
  })

  it('extracts @handle mentions while preserving trailing sentence periods and ignoring email addresses', () => {
    expect(splitMentions('Great light @Maya.r and @theo_shoots. Email me@example.com')).toEqual([
      'Great light ',
      { handle: 'maya.r', display: '@Maya.r' },
      ' and ',
      { handle: 'theo_shoots', display: '@theo_shoots' },
      '. Email me@example.com',
    ])
  })
})
