import { Controller, Get } from '@nestjs/common';
import { RequireAppAttest } from '../app-attest/app-attest.guard';

@RequireAppAttest()
@Controller('mobile/year-review')
export class YearReviewController {
  @Get(':year')
  get() {}
}
