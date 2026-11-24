import { Controller, Get, Put, UseGuards } from '@nestjs/common';
import { RequireAppAttest, AppAttestGuard } from '../app-attest/app-attest.guard';
import { AttestedRoute } from '../../common/decorators/attested.decorator';
import { KoreaderAuthGuard } from './koreader-auth.guard';

@UseGuards(KoreaderAuthGuard)
@Controller('koreader/plugin/catalog')
export class KoreaderCatalogController {
  @Get('books')
  books() {}

  @Get('books/:bookId')
  book() {}

  @Get('books/:bookId/thumbnail')
  @AttestedRoute()
  thumbnail() {}

  @Put('books/:bookId/read-status')
  setReadStatus() {}
}
