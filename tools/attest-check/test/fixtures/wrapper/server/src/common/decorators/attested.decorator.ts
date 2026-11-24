import { applyDecorators, Header } from '@nestjs/common';
import { RequireAppAttest } from '../../modules/app-attest/app-attest.guard';

export const AttestedRoute = () => applyDecorators(Header('Cache-Control', 'no-store'), RequireAppAttest());
