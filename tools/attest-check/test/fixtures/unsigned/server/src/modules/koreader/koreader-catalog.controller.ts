import { Controller, Get, Put, UseGuards } from '@nestjs/common';
import { RequireAppAttest, AppAttestGuard } from '../app-attest/app-attest.guard';
import { KoreaderAuthGuard } from './koreader-auth.guard';

@UseGuards(KoreaderAuthGuard)
@Controller('koreader/plugin/catalog')
export class KoreaderCatalogController {
  @Get('books')
  books() {}

  @Get('books/:bookId')
  book() {}

  @Get('books/:bookId/thumbnail')
  @RequireAppAttest({ unsignedOutsideProduction: true })
  thumbnail() {}

  @Put('books/:bookId/read-status')
  setReadStatus() {}
}
